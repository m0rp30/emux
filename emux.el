;;; emux.el --- Gestione sessioni SSH stile tmux -*- lexical-binding: t; -*-

;; Author: Luca Canali
;; Version: 0.1
;; Package-Requires: ((emacs "30.1"))
;; Keywords: tools, processes

;;; Commentary:
;; Pacchetto per gestire sessioni SSH in stile tmux.  In sviluppo.

;;; Code:
(require 'cl-lib)
(require 'subr-x)

;;;; Gruppo e opzioni del catalogo
(defgroup emux nil
  "Gestione di sessioni SSH in stile tmux."
  :group 'tools
  :prefix "emux-")

(defcustom emux-hosts-file
  (expand-file-name "emux-hosts.eld" user-emacs-directory)
  "File in cui emux salva il catalogo degli host.
Il contenuto è una lista di strutture `emux-host' in formato Lisp."
  :type 'file)

;; NOTE: possibile raffinamento futuro della modalità convivenza
;; (`emux-use-system-ssh-config' a t): passare sempre in modo esplicito
;; "-o" "Hostname=<hostname della struct>" nella riga di comando.  Le
;; opzioni -o da riga di comando vincono su qualsiasi blocco del config
;; di sistema, quindi un eventuale `HostName' in un blocco `Host'
;; combaciante non potrebbe più redirigere la connessione verso un'altra
;; macchina (scenario "mx": stesso nome corto per host aziendale e
;; personale).  Si erediterebbero le comodità globali (ControlMaster,
;; ServerAliveInterval...) blindando però la destinazione.
(defcustom emux-use-system-ssh-config nil
  "Se non-nil, ssh legge anche la configurazione di sistema dell'utente.
Quando è nil (il default), emux invoca ssh con \"-F /dev/null\": la
connessione dipende solo dal catalogo di emux, e nessun file di
configurazione esterno può interferire.

Quando è non-nil, ssh si comporta normalmente e legge anche
`~/.ssh/config'.  Attenzione: se l'hostname di un host emux combacia
con un pattern `Host' di quel file, ne eredita le opzioni; in
particolare una direttiva `HostName' può redirigere la connessione
verso una macchina diversa da quella attesa.  Attivare solo sapendo
cosa contiene il proprio `~/.ssh/config'."
  :type 'boolean)

;;;; Struttura dati
(cl-defstruct (emux-host (:constructor emux-host-create)
                         (:copier nil))
  "Host del catalogo emux.
Solo `name' e `hostname' sono obbligatori; gli slot a nil
delegano la decisione a ssh."
  (name nil :documentation "Etichetta unica per il completamento.")
  (hostname nil :documentation "FQDN o IP a cui connettersi.")
  (user nil :documentation "Utente remoto; nil = decide ssh o prompt.")
  (port nil :documentation "Porta; nil = default di ssh (22).")
  (identity-file nil :documentation "Percorso della chiave privata; nil = default di ssh.")
  (extra-options nil :documentation "Lista di stringhe passate tal quali a ssh."))

(defun emux--host-valid-p (object)
  "Vero se OBJECT è una struct `emux-host' ben formata.
Oltre al tipo verifica il numero di slot: `emux-host-p' controlla
solo il tag e accetterebbe record troncati (o allungati) prodotti
da un file manomesso, es.  \"#s(emux-host ...)\" con slot mancanti."
  (and (emux-host-p object)
       (= (length object) (length (emux-host-create)))))

;;;; Persistenza del catalogo
(defun emux--read-hosts ()
  "Restituisci la lista degli host letti da `emux-hosts-file'.
Se il file non esiste, restituisci nil (catalogo vuoto).
Segnala un errore se il contenuto non è una lista di `emux-host'."
  (if (not (file-exists-p emux-hosts-file))
      nil
    (let ((hosts (with-temp-buffer
                   (insert-file-contents emux-hosts-file)
                   (condition-case _
                       (read (current-buffer))
                     ((end-of-file invalid-read-syntax)
                      (error "File %s malformato: non è Lisp leggibile"
                             emux-hosts-file))))))
      (unless (and (listp hosts) (cl-every #'emux--host-valid-p hosts))
        (error "File %s malformato: attesa una lista di emux-host"
               emux-hosts-file))
      hosts)))

(defun emux--write-hosts (hosts)
  "Scrivi HOSTS, lista di `emux-host', in `emux-hosts-file'.
La scrittura è atomica: il contenuto va prima su un file
temporaneo nella stessa directory, poi un rename lo sostituisce
al file definitivo.  Il file ha permessi 600."
  (let* ((dir (file-name-directory (expand-file-name emux-hosts-file)))
         (temp (make-temp-file (expand-file-name "emux-hosts-" dir))))
    (unwind-protect
        (progn
          (with-temp-file temp
            (let ((print-length nil)
                  (print-level nil))
              (prin1 hosts (current-buffer))
              (insert "\n")))
          (rename-file temp emux-hosts-file t)
          (setq temp nil))
      (when temp
        (ignore-errors (delete-file temp))))))

;;;; Input dal minibuffer
(defun emux--read-optional-string (prompt &optional initial)
  "Leggi una stringa dal minibuffer con PROMPT, vuoto ammesso.
INITIAL, se non-nil, è il testo precompilato ed editabile.
Restituisci la stringa ripulita degli spazi, o nil se vuota.
Nel contratto di emux, nil significa \"decide ssh\"."
  (let ((s (string-trim (read-string prompt initial))))
    (if (string-empty-p s) nil s)))

(defun emux--read-identity-file (&optional initial)
  "Leggi il percorso di una chiave privata dal minibuffer.
INITIAL, se non-nil, è il percorso precompilato ed editabile.
Restituisci il percorso in forma abbreviata, o nil se l'input è
vuoto (= decide ssh).  Se il file indicato non esiste, avvisa
esplicitamente e chiedi se usarlo comunque; in caso negativo
ripropone il prompt."
  (let (result done)
    (while (not done)
      (let ((f (read-file-name
                "Chiave privata (vuoto = decide ssh): "
                (if initial (file-name-directory initial) "~/.ssh/")
                (or initial "")
                nil
                (and initial (file-name-nondirectory initial)))))
        (cond
         ((string-empty-p f)
          (setq result nil
                done t))
	 ((file-directory-p f)
          (message "%s è una directory, non una chiave"
                   (abbreviate-file-name f))
          (sit-for 1.5))
         ((file-exists-p f)
          (setq result (abbreviate-file-name f)
                done t))
         ((y-or-n-p (format "Attenzione: %s non esiste.  Usarlo comunque? "
                            (abbreviate-file-name f)))
          (setq result (abbreviate-file-name f)
                done t)))))
    result))

(defun emux--read-port (&optional initial)
  "Leggi un numero di porta dal minibuffer, vuoto ammesso.
INITIAL, se non-nil, è la porta attuale, precompilata ed
editabile.  Restituisci un intero tra 1 e 65535, o nil se
l'input è vuoto (= default di ssh).  Segnala un `user-error'
se l'input non è una porta valida."
  (let ((s (emux--read-optional-string
            "Porta (vuoto = default 22): "
            (and initial (number-to-string initial)))))
    (when s
      (unless (string-match-p "\\`[0-9]+\\'" s)
        (user-error "Porta non valida: %s" s))
      (let ((n (string-to-number s)))
        (unless (<= 1 n 65535)
          (user-error "Porta fuori intervallo (1-65535): %d" n))
        n))))

(defun emux--read-host (hosts prompt)
  "Chiedi di scegliere un host tra HOSTS con PROMPT nel minibuffer.
Restituisci la struct `emux-host' selezionata.  Segnala un
`user-error' se HOSTS è vuota."
  (unless hosts
    (user-error "Il catalogo è vuoto: aggiungi un host con emux-host-add"))
  (let ((name (completing-read prompt
                               (mapcar #'emux-host-name hosts)
                               nil t)))
    (cl-find name hosts :key #'emux-host-name :test #'string=)))

;;;; Connessione SSH
(defcustom emux-ssh-term "xterm-256color"
  "Tipo di terminale dichiarato ai server remoti nelle sessioni SSH.
Se non-nil, emux avvia ssh tramite \"env TERM=VALORE\": il valore
vale solo per il processo ssh, che lo comunica al server, mentre
il terminale locale resta quello del backend.  Serve perché i
backend usano spesso un tipo proprio (eat dichiara
\"eat-truecolor\") la cui descrizione terminfo di norma non esiste
sui server: programmi come htop falliscono con \"Error opening
terminal\".

Se nil, emux non tocca TERM e ssh trasmette quello impostato dal
backend.  È la scelta giusta se sui server è installata la
descrizione terminfo del backend, che ne conserva tutte le
capacità (per eat, truecolor incluso)."
  :type '(choice (string :tag "Tipo di terminale")
                 (const :tag "Usa TERM di sistema" nil)))

(defun emux--ssh-command (host &optional user identity-file)
  "Costruisci la riga di comando ssh per HOST, come lista di argomenti.
HOST è una struct `emux-host'.  USER e IDENTITY-FILE, se non-nil,
sono override one-shot che vincono sugli slot corrispondenti (la
struct non viene modificata).  I valori a nil, da override o da
slot, delegano la decisione a ssh.

Se `emux-ssh-term' è non-nil, il comando è preceduto da
\"env TERM=VALORE\": il tipo di terminale dichiarato al server
vale solo per ssh.  In tal caso il primo elemento della lista è
\"env\", non \"ssh\".

Con `emux-use-system-ssh-config' a nil il comando include
\"-F /dev/null\" e \"-o IdentitiesOnly=yes\": ssh ignora ogni file
di configurazione e offre solo le identità esplicite (la chiave
del catalogo, se presente, o i file di default in ~/.ssh), senza
attingere alle chiavi dell'agent.  Le `extra-options' dell'host
precedono le opzioni automatiche: in ssh vince la prima
occorrenza, quindi l'utente può annullarle (es.
\"-o IdentitiesOnly=no\" per riammettere l'agent)."
  (let ((user (or user (emux-host-user host)))
        (identity-file (or identity-file (emux-host-identity-file host)))
        (port (emux-host-port host))
        (hostname (emux-host-hostname host)))
    `(,@(when emux-ssh-term
          (list "env" (concat "TERM=" emux-ssh-term)))
      "ssh"
      ,@(unless emux-use-system-ssh-config '("-F" "/dev/null"))
      ,@(emux-host-extra-options host)
      ,@(when port (list "-p" (number-to-string port)))
      ,@(when identity-file (list "-i" (expand-file-name identity-file)))
      ,@(unless emux-use-system-ssh-config '("-o" "IdentitiesOnly=yes"))
      ,(if user (concat user "@" hostname) hostname))))

(defun emux--ssh-read-one-shot (host)
  "Chiedi i valori one-shot mancanti per connettersi a HOST.
Per ciascuno slot tra `user' e `identity-file' che in HOST è nil,
chiede il valore nel minibuffer; input vuoto = decide ssh.  Gli
slot già valorizzati non vengono chiesti.  Restituisce la lista
\(USER IDENTITY-FILE) di override, nello stesso ordine degli
argomenti opzionali di `emux--ssh-command'.  Il catalogo non
viene mai modificato."
  (list
   (unless (emux-host-user host)
     (emux--read-optional-string
      (format "Utente per %s (vuoto = decide ssh): "
              (emux-host-name host))))
   (unless (emux-host-identity-file host)
     (emux--read-identity-file))))

;;;; Backend terminale
(defcustom emux-terminal-backend 'eat
  "Backend usato da emux per i terminali delle sessioni SSH.
Il valore è un simbolo; per ogni backend deve esistere un metodo
di `emux--terminal-make' specializzato su quel simbolo.  Il
backend predefinito è `eat' (pacchetto NonGNU ELPA, puro Elisp)."
  :type '(choice (const :tag "Eat (Emulation A Terminal)" eat)
                 (symbol :tag "Altro backend")))

(cl-defgeneric emux--terminal-make (backend name command)
  "Crea un terminale con BACKEND che esegue COMMAND, e restituiscilo.
BACKEND è un simbolo su cui i metodi si specializzano (vedi
`emux-terminal-backend').  NAME è il nome logico della sessione,
senza decorazioni.  COMMAND è la riga di comando come lista di
stringhe: programma e argomenti, senza shell.

Ogni metodo deve: creare un buffer di terminale che esegue
COMMAND; chiamarlo esattamente \"*NAME*\" (asterischi inclusi:
i chiamanti ritrovano la sessione ricostruendo questo nome, e
l'idempotenza di `emux-connect-ssh' vi fa affidamento); NON
mostrarlo; restituirlo.  Mostrare il buffer è responsabilità
del chiamante.")

;;;; Backend eat
(declare-function eat-make "eat" (name program &optional startfile &rest switches))

(cl-defmethod emux--terminal-make ((_backend (eql 'eat)) name command)
  "Crea un terminale eat chiamato NAME che esegue COMMAND.
COMMAND è la riga di comando come lista di stringhe.  Il buffer
creato si chiama \"*NAME*\" (gli asterischi li aggiunge eat) e
NON viene mostrato.  Carica il pacchetto `eat' al primo uso;
segnala un errore parlante se non è installato.

Attenzione: con `eat-kill-buffer-on-exit' non-nil, eat uccide il
buffer alla morte del processo; della sessione resta solo la
notifica di emux (nome ed evento di uscita), non l'output del
terminale né gli eventuali messaggi d'errore.  emux rispetta la
configurazione dell'utente e non altera la variabile."
  (unless (require 'eat nil t)
    (error "Backend eat non disponibile: installa il pacchetto `eat' (NonGNU ELPA)"))
  (apply #'eat-make name (car command) nil (cdr command)))

;;;; Sessioni: strumenti comuni ai backend
(defcustom emux-display-policy 'window
  "Come emux presenta i buffer delle sessioni.
Con `window' (il default) le sessioni si mostrano come normali
buffer: la connessione può aprire una finestra, la navigazione
riusa quella corrente.  Con `tab' ogni sessione vive in una tab
dedicata di `tab-bar-mode', chiamata come la sessione (es.
\"ssh:mx\"): connessione e navigazione portano alla sua tab,
creandola se manca — l'esperienza è quella delle window di tmux.
La prima tab creata rende visibile la tab-bar in tutto il frame;
per mostrarla solo quando le tab sono più di una, vedi
`tab-bar-show'.  Le tab sono per-frame: in un workflow
multi-frame (daemon) ogni frame ha le proprie.  In entrambe le
modalità le regole di `display-buffer-alist' dell'utente hanno
la precedenza."
  :type '(choice (const :tag "Finestre normali" window)
                 (const :tag "Una tab per sessione (stile tmux)" tab)))

(defun emux--session-notify-on-exit (buffer name)
  "Avvisa nell'echo area quando il processo di BUFFER termina.
NAME è il nome logico della sessione, usato nel messaggio.  La
notifica si AGGIUNGE alla sentinella già installata dal backend,
senza sostituirla.  Se BUFFER non ha un processo, non fa nulla.
Restituisce BUFFER, per comporsi nelle pipeline dei chiamanti."
  (let ((proc (get-buffer-process buffer)))
    (when proc
      (add-function :after (process-sentinel proc)
                    (lambda (_proc event)
                      (message "emux: sessione %s terminata (%s)"
                               name (string-trim event))))))
  buffer)

(defun emux--session-quit-window-on-exit (buffer)
  "Rilascia la finestra di BUFFER quando il processo esce con successo.
Alla morte pulita del processo (evento \"finished\") la finestra
che mostra BUFFER viene congedata con `quit-restore-window': se
era stata creata per la sessione viene eliminata, altrimenti
torna al buffer precedente.  In caso di uscita anomala la
finestra resta: contiene la diagnostica.  Il destino di BUFFER
non viene toccato (decide il backend, per eat vedi
`eat-kill-buffer-on-exit').  Se BUFFER non ha un processo, non
fa nulla.  Restituisce BUFFER, per comporsi nelle pipeline."
  (let ((proc (get-buffer-process buffer)))
    (when proc
      (add-function :before (process-sentinel proc)
                    (lambda (_proc event)
                      (when (string-prefix-p "finished" event)
                        (let ((win (get-buffer-window buffer t)))
                          (when win
                            (quit-restore-window win 'bury))))))))
  buffer)

(defvar-local emux-session-host-name nil
  "Nome dell'host del catalogo a cui questo buffer è connesso.
Impostata da emux nei buffer di sessione; nil in tutti gli
altri.  È il marcatore con cui emux riconosce i propri buffer,
e la chiave per risalire all'host nel catalogo.  Da considerare
di sola lettura fuori da emux.")

(defun emux--session-mark (buffer host)
  "Marca BUFFER come sessione emux verso HOST, struct del catalogo.
Imposta `emux-session-host-name' buffer-locale in BUFFER col nome
di HOST.  Restituisce BUFFER, per comporsi nelle pipeline."
  (with-current-buffer buffer
    (setq emux-session-host-name (emux-host-name host)))
  buffer)

(defun emux--session-buffers ()
  "Restituisci i buffer delle sessioni emux vive.
Una sessione viva è un buffer che ha `emux-session-host-name'
impostato e un processo vivo.  La lista rispetta l'ordine di
`buffer-list': la sessione selezionata più di recente per prima.
Restituisce nil se non ci sono sessioni."
  (cl-remove-if-not
   (lambda (buffer)
     (and (buffer-local-value 'emux-session-host-name buffer)
          (process-live-p (get-buffer-process buffer))))
   (buffer-list)))

(defun emux--read-session (prompt)
  "Chiedi di scegliere una sessione emux viva, con completamento.
PROMPT è il testo del prompt, senza i due punti finali: il
default viene annotato da `format-prompt'.  Il completamento
avviene sui nomi degli host; il default è la sessione
selezionata più di recente diversa dal buffer corrente.
Restituisce il buffer della sessione scelta.  Segnala un
`user-error' se non ci sono sessioni vive."
  (let ((sessions (emux--session-buffers)))
    (unless sessions
      (user-error "Nessuna sessione attiva: apri con emux-connect-ssh"))
    (let* ((session-name
            (lambda (buffer)
              (buffer-local-value 'emux-session-host-name buffer)))
           (default
            (funcall session-name
                     (or (cl-find-if
                          (lambda (buffer)
                            (not (eq buffer (current-buffer))))
                          sessions)
                         (car sessions))))
           (name (completing-read (format-prompt prompt default)
                                  (mapcar session-name sessions)
                                  nil t nil nil default)))
      (cl-find name sessions :key session-name :test #'string=))))

(defun emux--session-cycle (offset)
  "Restituisci la sessione emux a OFFSET passi da quella corrente.
L'anello delle sessioni vive è ordinato alfabeticamente per nome
host (ordine stabile: non cambia con l'uso).  OFFSET è un intero,
tipicamente 1 o -1; l'anello è circolare in entrambi i versi.
Se il buffer corrente non è una sessione, restituisce la prima
dell'anello, qualunque sia OFFSET.  Segnala un `user-error' se
non ci sono sessioni vive."
  (let ((sessions (emux--session-buffers)))
    (unless sessions
      (user-error "Nessuna sessione attiva: apri con emux-connect-ssh"))
    (let* ((ring (sort sessions
                       :key (lambda (buffer)
                              (buffer-local-value 'emux-session-host-name
                                                  buffer))
                       :lessp #'string-lessp))
           (pos (cl-position (current-buffer) ring)))
      (if pos
          (nth (mod (+ pos offset) (length ring)) ring)
        (car ring)))))

(defun emux--session-display (buffer &optional navigating)
  "Mostra BUFFER, sessione emux, secondo `emux-display-policy'.
NAVIGATING non-nil dichiara che il chiamante sta navigando tra
sessioni esistenti; nil che ne sta aprendo una.  Con la politica
`window' la distinzione conta: navigazione nella finestra
corrente, apertura secondo `display-buffer'.  Con la politica
`tab' i due intenti coincidono: BUFFER va nella sua tab,
chiamata col nome logico della sessione (il nome del buffer
senza asterischi), creata se manca.  Restituisce la finestra
scelta, come `pop-to-buffer'."
  (pcase emux-display-policy
    ('tab
     (pop-to-buffer
      buffer
      `(display-buffer-in-tab
        (tab-name . ,(string-remove-suffix
                      "*" (string-remove-prefix
                           "*" (buffer-name buffer)))))))
    ('window
     (if navigating
         (pop-to-buffer-same-window buffer)
       (pop-to-buffer buffer)))
    (other
     (user-error "emux-display-policy sconosciuta: %s" other))))

;;;; Keymap
(defvar-keymap emux-repeat-map
  :doc "Repeat map per la navigazione tra sessioni emux.
Con `repeat-mode' attivo, dopo il primo `emux-next-session' o
`emux-previous-session' i tasti di questa mappa restano attivi
senza prefisso: n n p n...  Con `repeat-mode' spento non ha
alcun effetto."
  :repeat t
  "n" #'emux-next-session
  "p" #'emux-previous-session)

(defvar-keymap emux-command-map
  :doc "Keymap con i comandi di emux, da legare a un prefisso.
emux non occupa tasti globali: l'aggancio è una scelta
dell'utente, per esempio nel proprio init:

  (keymap-global-set \"C-c e\" emux-command-map)

Da lì: \\`c' connette, \\`s' cambia sessione, \\`n'/\\`p'
ciclano (ripetibili con `repeat-mode'), \\`a'/\\`e'/\\`d'
gestiscono il catalogo host."
  "c" #'emux-connect-ssh
  "s" #'emux-switch-session
  "n" #'emux-next-session
  "p" #'emux-previous-session
  "a" #'emux-host-add
  "e" #'emux-host-edit
  "d" #'emux-host-delete)

;;;; Comandi
;;;###autoload
(defun emux-connect-ssh (host)
  "Apri o riattacca la sessione SSH verso HOST, host del catalogo.
Interattivamente chiede quale host, con completamento.  Se il
buffer \"*ssh:NOME*\" esiste e il suo processo è vivo, lo mostra
\(riattacco: nessun prompt).  Altrimenti crea una nuova sessione
col backend `emux-terminal-backend', chiedendo one-shot gli
eventuali valori mancanti (utente, chiave); un buffer di sessione
morta con lo stesso nome viene eliminato e sostituito.  La
presentazione segue `emux-display-policy': con `tab' la sessione
vive nella sua tab dedicata.  Alla chiusura regolare della
sessione la finestra viene rilasciata; se la sessione muore con
un errore, la finestra resta.  Il catalogo non viene mai
modificato."
  (interactive (list (emux--read-host (emux--read-hosts) "Connetti a: ")))
  (let* ((name (concat "ssh:" (emux-host-name host)))
         (existing (get-buffer (concat "*" name "*"))))
    (if (and existing (process-live-p (get-buffer-process existing)))
        (emux--session-display existing)
      (when existing
        (kill-buffer existing))
      (pcase-let ((`(,user ,identity-file)
                   (emux--ssh-read-one-shot host)))
        (emux--session-display
         (emux--session-notify-on-exit
          (emux--session-quit-window-on-exit
           (emux--session-mark
            (emux--terminal-make emux-terminal-backend
                                 name
                                 (emux--ssh-command host user identity-file))
            host))
          name))))))

;;;###autoload
(defun emux-host-add ()
  "Aggiungi un host al catalogo di emux e salvalo su disco.
Chiede nome e hostname (obbligatori), poi utente, porta e chiave
\(opzionali: input vuoto = decide ssh).  Segnala un errore se il
nome è vuoto o già presente, o se la porta non è valida."
  (interactive)
  (let* ((hosts (emux--read-hosts))
         (name (string-trim (read-string "Nome (etichetta unica): "))))
    (when (string-empty-p name)
      (user-error "Il nome è obbligatorio"))
    (when (cl-find name hosts :key #'emux-host-name :test #'string=)
      (user-error "Un host di nome %s esiste già" name))
    (let ((hostname (string-trim (read-string "Hostname (FQDN o IP): "))))
      (when (string-empty-p hostname)
        (user-error "L'hostname è obbligatorio"))
      (let* ((user (emux--read-optional-string
                    "Utente (vuoto = decide ssh): "))
             (port (emux--read-port))
             (identity-file (emux--read-identity-file)))
        (emux--write-hosts
         (append hosts
                 (list (emux-host-create :name name
                                         :hostname hostname
                                         :user user
                                         :port port
                                         :identity-file identity-file))))
        (message "Host %s aggiunto al catalogo" name)))))

;;;###autoload
(defun emux-host-edit ()
  "Modifica un host del catalogo di emux e salvalo su disco.
Ripropone ogni campo precompilato col valore attuale: RET lo
conferma, il testo modificato lo sostituisce, svuotare un campo
opzionale lo riporta a nil (= decide ssh).  Qui si impostano
anche le opzioni extra passate tal quali a ssh."
  (interactive)
  (let* ((hosts (emux--read-hosts))
         (host (emux--read-host hosts "Modifica host: "))
         (name (string-trim (read-string "Nome (etichetta unica): "
                                         (emux-host-name host)))))
    (when (string-empty-p name)
      (user-error "Il nome è obbligatorio"))
    (when (cl-find-if (lambda (h)
                        (and (not (eq h host))
                             (string= (emux-host-name h) name)))
                      hosts)
      (user-error "Un host di nome %s esiste già" name))
    (let ((hostname (string-trim (read-string "Hostname (FQDN o IP): "
                                              (emux-host-hostname host)))))
      (when (string-empty-p hostname)
        (user-error "L'hostname è obbligatorio"))
      (let* ((user (emux--read-optional-string
                    "Utente (vuoto = decide ssh): "
                    (emux-host-user host)))
             (port (emux--read-port (emux-host-port host)))
             (identity-file (emux--read-identity-file
                             (emux-host-identity-file host)))
             (extra-options
              (let ((s (emux--read-optional-string
                        "Opzioni extra ssh (vuoto = nessuna): "
                        (combine-and-quote-strings
                         (emux-host-extra-options host)))))
                (and s (split-string-and-unquote s)))))
        (setf (emux-host-name host) name
              (emux-host-hostname host) hostname
              (emux-host-user host) user
              (emux-host-port host) port
              (emux-host-identity-file host) identity-file
              (emux-host-extra-options host) extra-options)
        (emux--write-hosts hosts)
        (message "Host %s aggiornato" name)))))

;;;###autoload
(defun emux-host-delete ()
  "Elimina un host dal catalogo di emux e salvalo su disco.
Chiede quale host eliminare (con completamento) e una conferma
esplicita prima di cancellare."
  (interactive)
  (let* ((hosts (emux--read-hosts))
         (host (emux--read-host hosts "Elimina host: "))
         (name (emux-host-name host)))
    (when (yes-or-no-p (format "Eliminare definitivamente l'host %s? " name))
      (emux--write-hosts
       (cl-remove name hosts :key #'emux-host-name :test #'string=))
      (message "Host %s eliminato dal catalogo" name))))

;;;###autoload
(defun emux-switch-session (buffer)
  "Mostra la sessione emux BUFFER.
Interattivamente chiede quale sessione con completamento tra le
sole sessioni vive; RET a input vuoto sceglie il default, la
sessione usata più di recente diversa da quella corrente (due
RET di fila rimbalzano quindi tra le ultime due sessioni).
La presentazione segue `emux-display-policy': con `window' la
sessione sostituisce il buffer della finestra corrente, come il
cambio di window in tmux; con `tab' porta alla tab della
sessione.  Le regole dell'utente in `display-buffer-alist'
possono disporre diversamente.  Segnala un `user-error' se non
ci sono sessioni vive."
  (interactive (list (emux--read-session "Sessione")))
  (emux--session-display buffer t))

;;;###autoload
(defun emux-next-session ()
  "Mostra la sessione emux successiva nell'anello delle sessioni.
L'anello è ordinato alfabeticamente per nome host ed è
circolare.  Da un buffer che non è una sessione, porta alla
prima dell'anello.  La presentazione segue
`emux-display-policy': con `tab' il passo avviene tra le tab
delle sessioni.  Vedi anche `emux-previous-session'."
  (interactive)
  (emux--session-display (emux--session-cycle 1) t))

;;;###autoload
(defun emux-previous-session ()
  "Mostra la sessione emux precedente nell'anello delle sessioni.
L'anello è ordinato alfabeticamente per nome host ed è
circolare.  Da un buffer che non è una sessione, porta alla
prima dell'anello.  La presentazione segue
`emux-display-policy': con `tab' il passo avviene tra le tab
delle sessioni.  Vedi anche `emux-next-session'."
  (interactive)
  (emux--session-display (emux--session-cycle -1) t))

(provide 'emux)
;;; emux.el ends here
