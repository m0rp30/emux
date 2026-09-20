# emux — Stato del progetto

## Obiettivo
Pacchetto per Emacs 30.2 chiamato `emux` per usare Emacs come una specie di
tmux e gestire sessioni SSH verso vari server. In un secondo momento anche
sessioni RDP (probabile lancio/gestione di xfreerdp come processo esterno;
argomento accantonato su indicazione dell'utente finché non lo richiederà).

## Metodo di lavoro (vincolante)
- Procedere rigorosamente a step, uno spezzone di codice alla volta.
- Ogni spezzone va mostrato, commentato riga per riga e testato prima di
  passare al successivo.
- Vietato rilasciare codice in blocco o intere funzioni non ancora discusse.
- Prima delle implementazioni, discutere design e alternative con pro e contro.
- L'utente vuole capire ogni passaggio, non solo avere codice funzionante.
- Minimizzare le dipendenze esterne; i backend (terminale, RDP) vanno sempre
  dietro uno strato di astrazione.
- Le correzioni si applicano sostituendo la funzione intera (grano giusto
  per `C-M-x`).

## Analogia guida (tmux ↔ Emacs)
- server tmux ↔ `emacs --daemon`
- attach/detach ↔ `emacsclient -t` / chiusura client
- window ↔ tab (`tab-bar-mode`, builtin)
- pane ↔ split di finestre Emacs
- prefix key ↔ keymap con prefisso da definire nel pacchetto

## Fatto finora

### Step 1 — Scheletro del pacchetto (completato)
File: `~/progetti/emux/emux.el`, scheletro convenzionale (prima riga con
lexical-binding, metadati, Commentary/Code, `provide`).

Concetti compresi: lexical vs dynamic binding; `provide`/`require`;
namespace `emux-`/`emux--`; checkdoc, byte-compile, `featurep`;
caricamento via `use-package :load-path`.

### Step 2 — Design: strutture dati e backend terminale (completato)
- **Host vs sessione**: configurazione statica e stato di runtime hanno
  cicli di vita diversi.
- **Host: `cl-defstruct`** (errori rumorosi, autodocumentazione, cl-lib
  builtin). Scartati stringhe semplici e alist/plist.
- **Sessioni: buffer come fonte di verità, nessun registro** (niente stato
  duplicato che diverge; idioma emacsiano: dired, TRAMP, ansi-term).
- **Niente persistenza sessioni su disco**: il caso d'uso è coperto dal
  workflow col daemon (`emacs --daemon` + `emacsclient -t`).
- **Backend terminale: `eat`** (puro Elisp, NonGNU ELPA, API `eat-make`,
  emulazione xterm quasi completa). Esclusi vterm (modulo C, attrito di
  installazione) e ansi-term (troppo minimale). Strato di astrazione
  dettagliato allo step 4 (dispatch: scelto `cl-defgeneric`).

### Step 3 — Catalogo host con CRUD (completato)
Verifica finale superata: checkdoc e byte-compile a freddo puliti.

#### Ridisegno architetturale dello step (decisione chiave)
Il piano originale (leggere `~/.ssh/config`) è stato **abbandonato** su
richiesta dell'utente, dopo discussione di tre opzioni:
1. Store tutto nostro, ssh_config ignorato.
2. emux come gestore di un file in sintassi ssh_config (con `-F` o Include).
3. Ibrido in sola lettura (scartata subito: niente CRUD).

**Scelta finale: Opzione 1 — emux possiede il catalogo e gestisce tutto.**
Requisiti espressi dall'utente: interfaccia per creare/modificare/eliminare
host con parametri opzionali (utente, chiave...); separazione netta tra
host di lavoro e privati; nessuna dipendenza dal config di sistema; emux
come mero layer sopra ssh.

Conseguenze di design:
- **Formato file: Lisp nativo** (`.eld`, `prin1`/`read`). Il parser
  ssh_config sparisce del tutto. Idioma usato da bookmark, recentf, ecc.
- **Costi accettati e registrati**: gli host emux non esistono fuori da
  emux (per l'utente è un pro: riservatezza); TRAMP allo step 6 richiederà
  di costruire noi i nomi `/ssh:user@host#port:`; le opzioni ssh esotiche
  passano dalla valvola di sfogo `extra-options`.
- **Connessione (realizzata allo step 4)**: comando costruito come lista di
  argomenti (niente shell, niente quoting), es.
  `("ssh" "-p" "2222" "-i" "chiave" "utente@hostname")`.

#### Isolamento dal config di sistema: default `-F /dev/null`
Analisi dello scenario "mx" (stesso nome corto per host aziendale e
personale): senza `-F`, ssh legge comunque `~/.ssh/config`; se l'hostname
di una struct combacia con un pattern `Host`, una direttiva `HostName`
può **redirigere la connessione verso un'altra macchina** (la riga di
comando non protegge: la destinazione non è un'opzione `-o`). Regole di
precedenza ssh studiate: (1) riga di comando vince sempre; (2) nel config
vince la prima occorrenza; (3) il matching avviene sul nome passato da noi.

Decisione (ragionando da distributori del pacchetto, principio di minima
sorpresa): **default isolato**. `defcustom emux-use-system-ssh-config`,
default `nil` = emux invoca ssh con `-F /dev/null`; opt-in consapevole a
`t` per la convivenza (docstring documenta il rischio).

Nel codice c'è una **NOTE** (sopra il defcustom) sul possibile raffinamento
futuro della modalità convivenza: passare esplicitamente
`-o Hostname=<hostname della struct>` per blindare la destinazione
ereditando però le comodità globali (ControlMaster, ServerAliveInterval...).

#### Semantica del prompt alla connessione (decisa qui, realizzata allo step 4)
**Semantica 1 — one-shot**: se `user`/`identity-file` mancano, emux chiede
al momento della connessione e passa il valore sulla riga di comando; il
catalogo NON viene modificato. La scrittura del file resta confinata nei
comandi CRUD. Alternative scartate: "chiedi e salva" (sporca il catalogo),
"chiedi e proponi di salvare" (aggiungibile in futuro senza rompere nulla).

#### Spezzoni completati

**Spezzone 1 — `defgroup emux` + `defcustom emux-hosts-file`**
Default: `(expand-file-name "emux-hosts.eld" user-emacs-directory)` —
non `~/.ssh/` (territorio di OpenSSH; il file non è in sintassi ssh_config).
Concetti: defgroup e gerarchia (`:group 'tools`), `:prefix`, defcustom vs
defvar (contratto pubblico vs stato interno; non sovrascrive valori già
impostati), `:type 'file`.

**Spezzone 2 — `defcustom emux-use-system-ssh-config` (boolean) + NOTE**
Concetti: convenzione NOTE/TODO/FIXME (commento per chi sviluppa vs
docstring per l'utente); `;;` vs `;` vs `;;;`; prima riga docstring
autosufficiente; idioma "Se non-nil"; escape `\"` e backquote+apice per i
riferimenti; aggancio implicito all'ultimo defgroup.
*Debug vissuto*: la defcustom "non si vedeva" → buffer Customize stantio
(non si auto-aggiorna: `g` per rigenerarlo). Metodo appreso: prima
"esiste?" (`C-h v`), poi `*Messages*`, poi `C-M-x` (`eval-defun`, che
forza anche il reset del default — eccezione deliberata), `check-parens`.

**Spezzone 3 — `cl-defstruct emux-host`**
Slot: `name` (obbligatorio, etichetta unica), `hostname` (obbligatorio),
`user`, `port`, `identity-file`, `extra-options` (tutti opzionali,
`nil` = decide ssh; extra-options = lista di stringhe passate tal quali).
Lo slot `type` per RDP NON è stato aggiunto: si aggiungerà quando servirà.
Opzioni: `(:constructor emux-host-create)` (namespace pulito),
`(:copier nil)` (niente copy shallow non richiesta).
Concetti: record = vettori taggati; costruttore con keyword args,
accessori con errori rumorosi, predicato, supporto setf; `:documentation`
per slot; validazione ai bordi, non nella struct; `(require 'cl-lib)` in
cima (dipendenza esplicita, non implicita).

**Spezzone 4 (+ 4-bis, 4-ter) — `emux--read-hosts` e `emux--host-valid-p`**
Contratto: file assente → nil (catalogo vuoto, non errore); file valido →
lista di struct; file corrotto → errore rumoroso (mai mascherare: il
successivo add sovrascriverebbe dati forse recuperabili).
Concetti: `with-temp-buffer` + `insert-file-contents` (non la machinery
dei file visitati); `read` = reader Lisp esposto; simmetria `prin1`/`read`;
`cl-every` e `#'`; `unless`+`error` con percorso nel messaggio.
*Bug trovati dai test dell'utente e corretti:*
1. File sintatticamente rotto → `read` sollevava "End of file during
   parsing" prima della nostra validazione. Fix (**4-bis**):
   `condition-case _` con condizioni `(end-of-file invalid-read-syntax)`
   (doppia parentesi per lista di condizioni!) attorno alla SOLA `read`
   (perimetro minimo: non mascherare errori di I/O), pattern
   cattura-e-traduci. Due messaggi distinti: "non è Lisp leggibile" vs
   "attesa una lista di emux-host".
2. Record troncato a mano (`#s(emux-host ...)` con 5 slot) → superava
   `emux-host-p` (controlla solo il tag!) e il crash esplodeva a valle
   (pretty-printer / accessori, `args-out-of-range`). Fix (**4-ter**):
   predicato severo `emux--host-valid-p` = tipo AND arità
   (`(= (length object) (length (emux-host-create)))` — il metro si
   auto-aggiorna se aggiungeremo slot); usato da `cl-every` nella lettura.
Il bordo di lettura regge: sintassi rotta, tipo sbagliato, arità
sbagliata (troncati e allungati), file assente.

**Spezzone 5 — `emux--write-hosts`**
Scrittura atomica: `make-temp-file` NELLA STESSA DIRECTORY del file
definitivo (l'atomicità del rename vale solo sullo stesso filesystem;
crea davvero il file, permessi 600 nativi, che il rename preserva) →
`with-temp-file` sul temporaneo → `rename-file ... t`.
`unwind-protect` con la danza `(setq temp nil)` / `(when temp (delete-file))`
per non lasciare orfani (e `ignore-errors` nella pulizia per non oscurare
l'errore originale).
Difesa di stampa: `let` di `print-length` e `print-level` a `nil`
(variabili dinamiche che potrebbero troncare la stampa con `...` →
file monchi). `prin1` (rileggibile) vs princ/print. Newline finale POSIX.
Niente validazione input: la scrittura non è un ingresso del sistema
(i dati arrivano dal nostro codice via costruttore).

**Spezzone 6 — `emux-host-add` (versione minima) + `(require 'subr-x)`**
Flusso deciso: prompt sequenziali nel minibuffer (no form, no transient =
dipendenza esterna); lettura catalogo PRIMA dei prompt (fail fast su file
corrotto); validazione ai bordi: nome obbligatorio non duplicato,
hostname obbligatorio; composizione leggi → modifica → scrivi (il file
resta l'unica fonte di verità, nessuno stato residente).
Concetti: `(interactive)` = ciò che rende comando una funzione (input
letto nel corpo, non nella spec: serve validazione passo-passo);
`user-error` vs `error` (colpa dell'utente vs bug; debug-on-error);
`string-trim`/`string-empty-p` (da subr-x, molte defsubst → require
esplicito); `cl-find :key :test #'string=` (il default `eql` sulle
stringhe non funziona: errore classico); `append` vs `cons` (ordine di
inserimento preservato); `message` di feedback.

**Spezzone 7 (+ 7-bis) — `emux-host-add` completa + helper**
Decisione di perimetro: il prompt di add chiede `user`, `port`,
`identity-file` ma NON `extra-options` (campo avanzato/raro: si imposta
via `emux-host-edit`, dove l'esigenza tipicamente emerge).
Helper `emux--read-optional-string`: input vuoto (trimmed) → nil =
"decide ssh" (fattorizzazione: il pattern ricorreva tre volte).
Porta: validazione con regexp `"\\`[0-9]+\\'"` PRIMA di
`string-to-number` (che non segnala mai errori: "abc"→0, "22abc"→22);
ancore di stringa `\\\`` `\\'` vs `^` `$` (ancore di riga); range check
`(<= 1 n 65535)` (comparatori n-ari).
Chiave: helper dedicato `emux--read-identity-file` (**7-bis**, su
richiesta dell'utente: avviso esplicito al posto del laconico "Confirm"
di `'confirm`): `read-file-name` con DEFAULT-FILENAME `""` (gotcha:
altrimenti input vuoto → directory corrente!), senza mustmatch; ciclo
`while` con bandiera `done` + `cond` (il ri-prompt emerge dal ramo
mancante); se il file non esiste → `y-or-n-p` "Attenzione: X non esiste.
Usarlo comunque?"; risposta n → ri-prompt della sola chiave (niente abort:
non si perdono i campi già digitati). `y-or-n-p` (basso rischio) vs
`yes-or-no-p` (irreversibile). `abbreviate-file-name` sul percorso
salvato (leggibilità + portabilità della home); `let*` = binding
sequenziali.

**Spezzone 8 — `emux--read-host` + `emux-host-delete`**
Helper di selezione estratto SUBITO (delete, edit e la connessione dello
step 4 iniziano tutti con "scegli un host"): riceve il catalogo come
argomento (il chiamante l'ha già letto: fail fast, niente doppia lettura)
e restituisce la STRUCT intera, non il nome (edit e connessione vogliono
tutto; decisione che paga in edit col confronto per identità).
Concetti: `completing-read` = punto di aggancio di tutti i framework di
completamento (vertico/ivy/default: si programma verso l'interfaccia
builtin, l'ecosistema fa il resto — stessa ragione dei prompt minibuffer
vs transient); argomenti PROMPT/COLLECTION/PREDICATE/REQUIRE-MATCH;
REQUIRE-MATCH `t` per delete (vs mustmatch tolto per la chiave: stesso
meccanismo, contratti opposti caso per caso); `mapcar` come proiezione
lista-di-struct → lista-di-nomi; catalogo vuoto intercettato PRIMA di
completing-read, con user-error che orienta ("aggiungi un host con
emux-host-add"); `yes-or-no-p` per la cancellazione (irreversibile);
risposta no = niente, in silenzio (rinunciare non è un errore);
`cl-remove` NON distruttivo (vs `cl-delete`: sicuro per default, stesso
spirito di `(:copier nil)`).
*Nota utente*: con `use-short-answers` a `t` (Emacs 28+) le yes-or-no-p
vengono servite come y-or-n-p — stratificazione corretta: il pacchetto
dichiara la severità, l'utente decide l'ergonomia. Il codice resta com'è.

**Spezzone 9 (+ 9-bis) — `emux-host-edit` + helper estesi**
Design: Opzione A — ripercorrere TUTTI i campi precompilati col valore
attuale (RET conferma, modifica sostituisce, svuotare un opzionale →
nil). Scartata (aggiungibile in futuro) la B: scelta del singolo campo.
**INITIAL-INPUT vs DEFAULT di `read-string`**: differenza NON cosmetica —
con DEFAULT il minibuffer parte vuoto e RET restituisce il default,
quindi il gesto "svuota il campo" diventerebbe inesprimibile; con
INITIAL il valore è nel minibuffer, editabile/cancellabile. INITIAL è
"mostly deprecated" TRANNE che per editare valori esistenti (nostro caso).
Helper estesi con `&optional initial` (retrocompatibile: add non si tocca).
Concetti: `cl-find-if` + prima lambda del progetto (criterio ad hoc);
controllo duplicati con auto-esclusione via `(not (eq h host))` — `eq` =
identità di oggetto, e host È l'oggetto nella lista (dividendo dello
spezzone 8); coppia `combine-and-quote-strings`/`split-string-and-unquote`
per extra-options (round-trip lista ↔ riga con quoting: argomenti con
spazi sopravvivono); `setf` a coppie multiple sugli slot; mutazione della
struct sul posto LECITA perché la lista è appena letta e locale al comando
(eccezione argomentata al non-distruttivo dello spezzone 8).
*Bug trovato dall'utente e corretto (**9-bis**)*: in edit, RET secco sul
campo chiave azzerava lo slot. Causa: seconda regola speciale di
`read-file-name` — input ESATTAMENTE UGUALE alla stringa pre-inserita →
restituisce DEFAULT-FILENAME, che era `""` → nil. Fix: DEFAULT-FILENAME
= `(or initial "")` — con precompilazione il default DEVE essere il
valore attuale, altrimenti "conferma" e "azzera" collassano. I due canali
di conferma ora convivono: RET invariato → conferma; campo svuotato →
nil. Gotcha gemella (per i file) della distinzione INITIAL/DEFAULT.
In `read-file-name` con INITIAL: il percorso va SPEZZATO
(`file-name-directory` come DIR, `file-name-nondirectory` come INITIAL),
altrimenti DIR+INITIAL concatenati mostrano `~/.ssh/~/.ssh/chiave`.

**Spezzone 10 — saldo debiti + pulizia finale**
Debito 1 — `emux--read-port` (`&optional initial`): estratto con DUE sole
occorrenze, in deroga argomentata alla regola delle tre — per la logica
di validazione a più stadi (regexp, conversione, range, messaggi che
devono restare identici) il costo del duplicato supera il costo
dell'astrazione già a quota due; la regola delle tre è calibrata sui
pattern banali. L'helper compone `emux--read-optional-string`
(stratificazione = ricompensa della fattorizzazione); il prompt trasloca
nell'helper (era identico nei chiamanti); `user-error` negli helper è
lecito: il criterio non è "comando vs funzione" ma "chi possiede il
dialogo". In add sparisce la catena port-string→port dal `let*`.
Debito 2 — ramo `file-directory-p` in `emux--read-identity-file`: le
directory ESISTONO per `file-exists-p`, quindi il ramo va PRIMA (ordine
delle clausole = correttezza, non solo leggibilità: dopo sarebbe codice
morto silenzioso); il ramo non imposta `done` → ri-prompt emergente;
`message` + `sit-for` 1.5 (attesa interrompibile dall'input) perché il
prompt successivo coprirebbe il messaggio: feedback invisibile =
inesistente; per una presa d'atto senza decisione è più leggero di
y-or-n-p.
Pulizia: `checkdoc` (convenzioni documentali; tarato sull'inglese: le
segnalazioni strutturali si correggono, quelle linguistiche si valutano)
e `byte-compile` = analizzatore statico (funzioni non definite, variabili
libere, arità). Test onesto A FREDDO:
`emacs -Q --batch -f batch-byte-compile emux.el`.
Gotcha del `.elc` stantio in sviluppo: Emacs preferisce il `.elc` al
`.el` → compilare per verificare, poi `rm emux.elc`.
Verifica finale superata: esiti puliti, step chiuso.

### Step 4 — Apertura sessione SSH (completato)
Chiusura formale superata: checkdoc e byte-compile a freddo puliti
sull'intero file, `rm emux.elc` eseguito.

#### Decisioni di apertura
- **Dispatch dei backend: Opzione A — `cl-defgeneric` + `cl-defmethod`
  con specializzatore `(eql ...)`.** Alternative discusse e scartate:
  `pcase` in funzione centrale (chiuso: ogni backend nuovo richiede di
  editare il core, violazione aperto/chiuso) e registro alist
  simbolo→funzione (idioma soppiantato dai generici nell'Emacs moderno,
  contratto solo implicito). Ragioni della A: il defgeneric È lo strato
  di astrazione fatto linguaggio (vincolo di progetto); estensibilità
  aperta (un backend si aggiunge scrivendo un metodo, anche in un altro
  file — come project.el, xref, TRAMP); errore `cl-no-applicable-method`
  gratis; idioma reale da imparare; tutto builtin.
- **Nome del comando: `emux-connect-ssh`** (scelto dall'utente): famiglia
  di nomi simmetrica per protocolli futuri — `emux--ssh-command` /
  `emux-connect-ssh` oggi, `emux--rdp-command` / `emux-connect-rdp`
  domani.
- **Perimetro dell'astrazione**: riguarda il backend *terminale* (eat
  oggi, magari vterm domani). RDP non passerà da qui (xfreerdp non è un
  programma da terminale): il contratto non è stato forzato a coprirlo.

#### Spezzone 1 (→ 1-bis → 1-ter) — `emux--ssh-command`
Funzione PURA (niente prompt, niente I/O): struct → lista di argomenti.
Firma `(host &optional user identity-file)`: gli opzionali sono il
canale degli override one-shot (vincono sugli slot via `or`; la struct
non si tocca mai — scartata la mutazione/copia della struct).
Composizione della lista con **backquote + splicing**: `` ` `` congela,
`,` valuta e inserisce UN elemento, `,@` valuta e RIVERSA una lista;
`,@nil` riversa zero elementi, e `when`/`unless` restituiscono nil a
condizione fallita → i pezzi opzionali svaniscono da soli. Il template
si legge come stampino del comando. (Alternativa scartata: `append` di
sottoliste — stesso trucco, leggibilità peggiore.)
Concetti: `number-to-string` al bordo di uscita (speculare alla
validazione al bordo di ingresso); `expand-file-name` sulla chiave —
simmetria con `abbreviate-file-name` dello spezzone 7: *abbrevia quando
scrivi per umani, espandi quando parli con processi* (niente shell =
niente espansione di `~` garantita); destinazione `user@host` (niente
`-l`) SEMPRE ultima (ssh esige le opzioni prima della destinazione);
niente quoting per costruzione (lista di argomenti, ogni stringa = un
argomento, spazi inclusi).
Evoluzioni (dall'incidente ssh, vedi sotto):
- **1-bis** (superata): `IdentitiesOnly=yes` legato al `-i`;
  extra-options spostate PRIMA delle opzioni automatiche.
- **1-ter** (VIGENTE): `-o IdentitiesOnly=yes` SEMPRE in modalità
  isolata, sganciato dalla chiave — stessa `unless` del `-F /dev/null`:
  due isolamenti gemelli (dal config e dall'agent) sotto la stessa
  manopola `emux-use-system-ssh-config`. Ordine del template: "ssh" →
  [-F /dev/null] → extra-options dell'host → [-p porta] → [-i chiave] →
  [-o IdentitiesOnly=yes] → destinazione. Le extra-options PRECEDONO le
  opzioni automatiche perché in ssh tra opzioni ripetute VINCE LA PRIMA
  OCCORRENZA: l'utente può annullare i nostri automatismi (es.
  `-o IdentitiesOnly=no` riammette l'agent) senza che emux scriva un if.
  Il contratto di nil si precisa: isolati = "decide ssh, senza
  interferenze di config e agent"; convivenza = "decide ssh, tutto lui".

#### Spezzone 2 — `emux--ssh-read-one-shot`
Realizza la semantica 1 dello step 3. Helper dedicato (scartati: prompt
inline nel comando — pentolone non testabile; helper che restituisce
l'argv completo — rimescola I/O e costruzione).
Prende la struct, chiede SOLO gli slot nil tra user e identity-file
(riusando `emux--read-optional-string` e `emux--read-identity-file`:
la fattorizzazione dello step 3 paga), restituisce la lista posizionale
`(USER IDENTITY-FILE)` — stesso ordine della firma di
`emux--ssh-command`: le due funzioni combaciano per costruzione.
Concetti: `unless` come ESPRESSIONE (restituisce nil a condizione vera →
niente prompt = niente override, e gli `or` a valle fanno il resto: gli
incastri sono nel design, non nel codice); il prompt NOMINA l'host
(`"Utente per %s"`): contesto nel minibuffer. Non riceve il catalogo:
non potrebbe salvare neanche volendo. "Chiedi e proponi di salvare"
resta aggiungibile qui dentro in futuro.
Consumo nel comando via `pcase-let` con pattern backquote
`` `(,user ,identity-file) ``: il backquote che allo spezzone 1
COSTRUIVA qui DESTRUTTURA — stesso stampino, direzione opposta.

#### Spezzone 3 — manopola + contratto
**`defcustom emux-terminal-backend`**, default `'eat` (APICE nel default:
è un'espressione valutata; il simbolo nudo sarebbe una variabile).
`:type '(choice (const :tag "..." eat) (symbol :tag "Altro backend"))`:
i backend noti elencati (documentazione viva) ma insieme APERTO — un
backend di terze parti si seleziona da Customize senza patchare emux
(la traduzione in UI dell'opzione A).
**`cl-defgeneric emux--terminal-make (backend name command)`**: contratto
puro, nessun corpo. Il dispatch avviene SUGLI ARGOMENTI → la variabile
va passata come argomento, non letta nel corpo (idioma xref). BACKEND
primo argomento (convenzione: l'argomento di dispatch davanti). Chiamata
senza metodo applicabile → `cl-no-applicable-method`, errore rumoroso
gratis. Doppio trattino sul generico = "non chiamarmi dal codice utente",
non "non estendermi" (accettato nell'ecosistema, cfr. project.el).
Docstring aggiornata allo **spezzone 5-bis** (vedi sotto): QUATTRO
obblighi per ogni metodo — (1) crea un buffer di terminale che esegue
COMMAND; (2) chiamalo esattamente `*NAME*` (asterischi inclusi: i
chiamanti ritrovano la sessione ricostruendo il nome, l'idempotenza di
`emux-connect-ssh` vi fa affidamento); (3) NON mostrarlo (la
presentazione è del chiamante); (4) restituiscilo. La regola del nome è
stata PROMOSSA dal metodo al generico quando il comando ha iniziato a
dipenderne: *specification vs implementation notes* — le specifiche non
si lasciano sepolte nelle implementazioni.

#### Spezzone 4 (→ 4-ter) — backend eat
`cl-defmethod` con specializzatore **`(eql 'eat)` QUOTATO**: da Emacs 28
l'argomento di eql è una forma valutata; il simbolo nudo è deprecato.
`_backend` = convenzione underscore per parametro deliberatamente
inutilizzato (l'informazione è consumata dal dispatch); il byte-compiler
tace.
**`require` pigro**: `(require 'eat nil t)` DENTRO il metodo (il core di
emux non dipende da eat: dipende solo chi lo implementa), con NOERROR
per sostituire l'errore generico con uno parlante ("installa il
pacchetto eat, NonGNU ELPA").
**`apply`**: `eat-make` vuole `(NAME PROGRAM &optional STARTFILE &rest
SWITCHES)` — argomenti separati, non lista. `(apply #'eat-make name
(car command) nil (cdr command))`: apply riversa l'ultima lista come
argomenti individuali (duale runtime dello `,@`); il nil riempie
STARTFILE. `car`/`cdr` smontano la lista `(PROGRAMMA . ARGOMENTI)`.
**`declare-function eat-make "eat" (...)`**: patto col byte-compiler per
la compilazione a freddo (eat non caricato = warning falso "not known to
be defined"); controlla anche l'arità delle nostre chiamate. Verificato
funzionante nella compilazione finale.
*Correzione a un'anticipazione*: `eat-make` NON mostra il buffer (a
mostrare è il comando interattivo `eat`; eat-make è modellata su
make-term: crea, avvia, restituisce). Contratto rispettato gratis.
**4-ter — docstring estesa** (solo docstring, codice intatto): documenta
l'interazione con `eat-kill-buffer-on-exit` (vedi sotto) e DICHIARA la
politica: "emux rispetta la configurazione dell'utente e non altera la
variabile" — impegno documentato, non assunzione implicita.

#### INCIDENTE SSH (debug vissuto, capitolo maggiore dello step)
*Sintomo iniziale*: host a password (localhost), il buffer "si apriva e
chiudeva al volo" — ssh usciva PRIMA di arrivare all'autenticazione.
L'host con identity-file funzionava perfettamente.

*False piste bruciate in ordine*:
1. `~/.ssh/config` dell'utente — non esiste.
2. `-F /dev/null` taglia anche `/etc/ssh/ssh_config` (+ ssh_config.d/):
   i test "in terminale funziona" NON erano equivalenti al comando emux.
   Vero in generale, ma non era la causa.
3. "emux passa una password errata" (ipotesi utente) — IMPOSSIBILE per
   costruzione: emux costruisce solo una lista di argomenti, non esiste
   un canale da cui possa uscire una password; ssh la chiede
   interattivamente sul terminale.

*Diagnosi finale (confermata dai test dell'utente)*:
- `Too many authentication failures` = il server chiude dopo
  `MaxAuthTries` (default 6) tentativi; ogni CHIAVE RIFIUTATA conta come
  tentativo, prima ancora di arrivare alla password.
- Le identità offerte in raffica arrivano da DUE sorgenti, e il budget è
  la SOMMA: (a) le chiavi dell'**agent**; (b) i **file di default su
  disco** — lista CHIUSA di nomi esatti che ssh prova da sé: id_rsa,
  id_ecdsa, id_ecdsa_sk, id_ed25519, id_ed25519_sk, id_xmss (+ fossile
  id_dsa). Le chiavi con nomi custom NON vengono mai offerte
  spontaneamente.
- La differenza terminale/Emacs: in terminale NIENTE agent
  (`ssh-add -l` → "Could not open a connection...") → raffica corta dei
  soli file di default, sotto budget, password raggiunta. DENTRO Emacs
  `SSH_AUTH_SOCK=/run/user/1000/gcr/ssh`: l'**agent di GNOME Keyring
  (gcr)**, ereditato dalla sessione grafica, aggiungeva le sue chiavi
  alla raffica → budget esploso, mai arrivati alla password.
- **`PerSourcePenalties` (OpenSSH ≥ 9.8, attive di default)**: sshd
  accumula penalità PER INDIRIZZO SORGENTE a ogni fallimento e rifiuta
  le connessioni oltre soglia. Stato lato server INVISIBILE dal client.
  Circolo vizioso: ogni riprova "per vedere se è passata" rinnova le
  penalità e allunga l'attesa — per questo il blocco "non passava mai" e
  a un certo punto falliva anche il terminale sano. Azzeramento: restart
  di sshd (stato in memoria) o attesa SENZA toccare nulla. Lezione: nei
  problemi con stato lato server, ogni osservazione modifica lo stato
  osservato in peggio; sequenza corretta: cura → azzera → verifica UNA
  volta. Per il banco di prova suggerita (opzionale) l'esenzione:
  `PerSourcePenaltyExemptList 127.0.0.0/8,::1` in sshd_config.

*Cura di design (→ spezzone 1-ter)*: isolare emux dall'AGENT, non
dall'autenticazione a chiave: `IdentitiesOnly=yes` sempre in modalità
isolata. Semantica precisa dell'opzione: limita le identità offerte a
quelle CONFIGURATE (chiave del catalogo via -i, o file di default su
disco), esclude SOLO le chiavi extra dell'agent; NON disabilita la
password (filtra chiavi, non metodi). Effetto: Emacs pareggiato al
terminale-senza-agent, che era lo scenario funzionante.

*Alternative scartate (proposte dall'utente, discusse)*:
- `PreferredAuthentications=password` automatico per gli host senza
  chiave: romperebbe il caso di massa (host senza identity-file che si
  autenticano via file di default o agent; server moderni con
  `PasswordAuthentication no` → host inconnettibili) e tradirebbe il
  contratto "nil = decide ssh".
- `IdentitiesOnly=no` esplicito quando la chiave manca: è già il default
  di ssh, documenterebbe il nulla.

*Residuo ACCETTATO E REGISTRATO*: host a password + ~5-6 chiavi tutte
con nomi standard su disco può ancora bruciare il budget (IdentitiesOnly
non tocca i file di default: sono identità configurate). Scenario raro
(chi ha molte chiavi le ha con nomi custom), in PARITÀ col comportamento
di ssh nudo senza agent; l'informazione "questo host va a password" ce
l'ha solo l'utente → cura DICHIARATIVA per-host:
`-o PreferredAuthentications=password` in extra-options via edit
(salta la fase a chiave pubblica: password subito). Chi vuole l'agent su
un host: `-o IdentitiesOnly=no` in extra-options (precede il nostro yes,
prima occorrenza vince). Se il residuo si rivelasse frequente: possibile
in futuro intercettare il fallimento e suggerire la cura.

#### Spezzone 4-bis — `emux--session-notify-on-exit`
Nato dalla richiesta utente "nessun allerta quando la sessione moriva"
(principio spezzone 10: feedback invisibile = inesistente).
Helper che opera sul BUFFER RESTITUITO dal backend (scartati: dentro il
metodo eat — duplicazione per ogni backend futuro; inline nel comando —
non testabile, non riusabile per RDP). Conferma che il contratto
"restituisci l'oggetto" era giusto.
Meccanismo: **sentinelle di processo** + **`add-function :after` su un
POSTO** — `(process-sentinel proc)` è una generalized variable (stessa
famiglia del setf sugli slot); la nostra notifica si AGGIUNGE alla
sentinella di eat senza sostituirla (set-process-sentinel l'avrebbe
rubata: eat la usa per i propri affari). `:after` = eat prima, integra,
noi dopo. Fratello di advice-add (simboli vs posti), stessa etica:
comporre senza toccare il codice altrui.
Concetti: `get-buffer-process`; **closure lessicale al lavoro** (la
lambda cattura `name` dall'ambiente e se lo porta nell'event loop —
possibile solo per il lexical-binding della prima riga del file);
`_proc` underscore; `(string-trim event)` (le stringhe-evento arrivano
col newline storico); il messaggio nomina la sessione e resta in
`*Messages*`. NIENTE race: le sentinelle non sono interrupt, Emacs le
dispaccia solo quando riprende fiato — l'aggancio sincrono precede
sempre l'evento. Restituisce il buffer (trasparenza per le pipeline).
*Perimetro dichiarato*: copre "la sessione è morta" (incluso il futuro
"connessione caduta"); NON distingue "morta subito = mostra il buffer":
politica di presentazione eventualmente del comando, da valutare solo se
il messaggio nudo non bastasse all'uso reale.

#### `eat-kill-buffer-on-exit`: il filo ritrovato e la decisione
Il primissimo sintomo "il buffer si chiudeva al volo" non era il default
di eat: nella config dell'utente `eat-kill-buffer-on-exit` è `t` (eat
uccide il buffer alla morte del processo). La notifica sopravvive
comunque (la closure usa solo `name`, non il buffer).
Conflitto di principi discusso: rispetto della config utente (cfr. nota
`use-short-answers`, spezzone 8) vs diagnosticabilità (il post-mortem
evapora). Opzioni: (a) documentare; (b) nil buffer-locale nei soli
buffer emux; (c) defcustom emux dedicata.
**Decisione dell'utente: (a) documentare e basta** — le variabili degli
extra package sono territorio loro. Documentata nella docstring del
metodo eat (4-ter: doc backend-specifica nel codice backend-specifico,
visibile da `C-h f emux--terminal-make`), con la politica dichiarata.
*Costo informato*: alla morte resta la notifica (nome + evento con exit
code), NON l'output del terminale né i messaggi d'errore di ssh; per un
fallimento misterioso la prima mossa sarà mettere temporaneamente la
variabile a nil e riprodurre. La (b) resta aggiungibile senza rompere
nulla.

#### Spezzone 5 — `emux-connect-ssh`
Tre decisioni di design:
1. **`(interactive (list (emux--read-host ...)))` — forma piena della
   spec**, prima volta nel progetto. Criterio emerso: input singolo e
   autonomo → spec; dialogo multi-campo con validazione → corpo (i CRUD
   restano com'erano). Guadagno: il comando è chiamabile
   PROGRAMMATICAMENTE con una struct (chiamanti futuri già in roadmap:
   layout step 5, simmetria RDP). Fail fast ereditato: catalogo
   corrotto/vuoto ferma tutto prima del corpo.
2. **Idempotenza PRIMA dei prompt**: riattacco a sessione viva = zero
   domande (l'ordine inverso chiederebbe valori da buttare).
3. **Buffer morto omonimo → kill e ricrea** (opzione c; scartate: riuso
   del buffer — meccanica backend-specifica, romperebbe l'astrazione;
   tenere e crearne un altro — `*ssh:mx*<2>` violerebbe "un host, un
   buffer"). Chiedere la connessione = dichiarazione implicita "ho
   finito col post-mortem". Costo registrato: il secondo fallimento
   sostituisce il primo buffer diagnostico (ma ne lascia uno fresco).
Concetti: cookie **`;;;###autoload`** sul punto d'ingresso (stub di
caricamento per i gestori di pacchetti; M-x possibile senza load
preventivo). `process-live-p` ACCETTA nil senza errore (controllo di
tipo interno) → la catena get-buffer → get-buffer-process →
process-live-p gestisce i degeneri senza guardie. `kill-buffer` su
terminale morto non chiede conferme (niente file visitato, niente
processo vivo). `pcase-let` destruttura il one-shot (anteprima dello
spezzone 2 mantenuta). Pipeline senza variabili d'appoggio:
`emux--ssh-command` → `emux--terminal-make` (backend dalla manopola,
passato come argomento di dispatch) → wrapper di sessione →
`pop-to-buffer`. **`pop-to-buffer` e non `switch-to-buffer`**: rispetta
`display-buffer` e le regole utente — noi dichiariamo "mostra", l'utente
decide come (stessa filosofia severità/ergonomia).
*Micro-debito registrato*: il cookie autoload spetterebbe anche ai CRUD
dello step 3 — da saldare in una pulizia futura.

#### Spezzone 5-ter — `emux--session-quit-window-on-exit`
Dalla segnalazione utente: a fine sessione la FINESTRA dello split
restava (con qualunque valore di eat-kill-buffer-on-exit). Causa:
finestre e buffer hanno vite separate — uccidere un buffer non elimina
le finestre che lo mostravano. La cura è del NOSTRO strato (chi apre la
finestra la rilascia), non di eat (gestisce buffer, non finestre).
Politica decisa: **la finestra si chiude SOLO su uscita pulita**
(evento "finished" = exit code 0). Su morte anomala RESTA: contiene la
diagnostica (chiuderla riprodurrebbe il problema del 4-bis).
Implicazione: `exit` digitato chiude; caduta di rete (ssh esce 255) no.
Ammorbidibile in futuro se sul campo desse fastidio (un string-prefix-p
da toccare, non un ridisegno).
Concetti chiave:
- **`add-function :before`, e stavolta l'ORDINE È CORRETTEZZA**: con
  eat-kill-buffer-on-exit a t la sentinella di eat uccide il buffer; in
  `:after` troveremmo il buffer già morto e la finestra già riassegnata.
  `:before` gira a buffer vivo. (La notifica resta `:after`: non le
  serve il buffer, e "prima il fatto, poi l'annuncio".) Lezione gemella
  del ramo file-directory-p dello spezzone 10.
- **`quit-restore-window win 'bury`** e non delete-window: è la macchina
  del tasto `q` dei buffer di help — ogni finestra di display-buffer
  ricorda come è nata; se creata apposta la ELIMINA (split ripristinato),
  se unica/riusata RIPRISTINA il buffer precedente, mai errori. `'bury`:
  il buffer NON viene ucciso — il suo destino resta a eat e alla config
  utente (con 'kill scavalcheremmo la variabile che il 4-ter promette di
  rispettare).
- `(get-buffer-window buffer t)`: t = tutti i frame (workflow daemon
  multi-frame in roadmap).
- Composizione a TRE strati sulla stessa sentinella: :before nostra
  chiusura-finestra → sentinella di eat → :after nostra notifica. Ogni
  pezzo vede lo stato che gli serve; due helper separati perché
  responsabilità e momenti diversi.

#### Spezzone 5-bis — promozione del contratto del nome
Sola docstring del generico (vedi spezzone 3 per il testo): la regola
"nome logico → `*NAME*`" promossa da nota del metodo eat a OBBLIGO del
contratto, con la RAGIONE accanto (l'idempotenza vi fa affidamento — chi
devia sa cosa rompe). La docstring del metodo eat resta come nota di
conformità ("gli asterischi li aggiunge eat"); un backend il cui toolkit
non li aggiunge dovrà aggiungerli lui.

### Step 5 — Layout stile tmux (completato)
Chiusura formale superata: checkdoc e byte-compile a freddo puliti
sull'intero file, `rm emux.elc` eseguito.

#### Decisioni di apertura (quattro questioni)
- **Questione 0 — riconoscimento delle sessioni: Opzione B, variabile
  buffer-locale marcatore**, impostata dal CHIAMANTE (non dal metodo
  backend: il contratto del generico non si allunga, ogni backend futuro
  la eredita gratis). Scartata la A (convenzione sul nome `*ssh:...*`):
  fragile ai falsi positivi e parsing "da archeologi". La B è fedele a
  "lo stato vive nel buffer" (non un registro esterno: un'etichetta
  sull'oggetto stesso; idioma dired-directory, TRAMP, compilation).
- **Questione 1 — tab**: meccanismo `tab-bar-mode` (la tab è una window
  configuration → dentro puoi splittare: l'analogia window+pane di tmux
  regge per intero; scartata tab-line-mode, buffer-switcher visuale).
  Politica: **manopola `defcustom emux-display-policy`** (Opzione 2;
  scartate "sempre tab" — invadente — e "solo display-buffer-alist" —
  feature ridotta a manuale). **Default deciso a fine step, dopo prova
  dal vivo della modalità tab: `window`** (minima sorpresa; la sorpresa
  di tab è solo estetica, quindi raccomandazione più leggera del caso
  `-F /dev/null`, ma stessa logica da distributori).
- **Questione 2 — prefix key**: `defvar-keymap` (idioma moderno, 29+);
  emux NON occupa tasti globali (convenzione del manuale: `C-c <lettera>`
  è riservato all'utente) — definisce la mappa, l'aggancio è dell'utente.
- **Questione 3 — navigazione**: `emux-switch-session` +
  `emux-next-session`/`emux-previous-session`. Un eventuale
  `emux-list-sessions` (tabulated-list) resta estensione futura, fuori
  perimetro.

#### Spezzone 1 — marcatore: `emux-session-host-name` + `emux--session-mark`
- **Contenuto: il NOME dell'host, non la struct** — la struct sarebbe una
  fotografia che diverge dal catalogo dopo un edit (due verità); il nome
  è una CHIAVE: chi vorrà i dettagli (step 6, TRAMP) rileggerà il file,
  unica fonte di verità. Costo registrato: rinomina/delete dell'host a
  sessione viva → chiave che non risolve più (accettabile: la sessione
  ssh non ha più bisogno del catalogo; il problema sarebbe identico con
  la struct).
- **UN trattino, deroga argomentata al `--`**: è una proprietà
  OSSERVABILE del buffer (leggibile da display-buffer-alist, mode-line,
  snippet utente), non un ingranaggio — idioma `dired-directory`:
  pubblica in lettura, scritta solo da emux (lo dice la docstring).
- Wrapper `emux--session-mark` PIÙ INTERNO della pipeline (battesimo
  appena il backend consegna): scelta di leggibilità ("prima chi è, poi
  cosa fare quando muore"), non di correttezza.
Concetti: **`defvar-local`** = defvar + make-variable-buffer-local: ogni
setq in qualunque buffer crea una copia locale, il globale (nil) non si
tocca mai — il meccanismo di major-mode, buffer-file-name;
`with-current-buffer` per SCRIVERE in un altro buffer; la variabile
sopravvive a rename-buffer e muore con kill-buffer (zero pulizia).

#### Spezzone 2 — `emux--session-buffers`
- **Definizione operativa di "sessione emux viva" per tutto lo step:
  marcatore E processo vivo.** Buffer morti col marcatore = post-mortem,
  non sessioni (navigarci sarebbe assurdo; per riattaccarli c'è connect).
  Elenco dei cadaveri eventualmente via argomento opzionale futuro.
- **Restituisce BUFFER, non nomi** (stesso argomento dello spezzone 8
  step 3: i consumatori vogliono l'oggetto; la proiezione a nomi la fa
  il chiamante con mapcar).
- **Ordine MRU preservato e DICHIARATO nel contratto** (`buffer-list` è
  già MRU): pagherà in switch (default), NON va usato per ciclare.
Concetti: **`buffer-local-value`** per LEGGERE una variabile in un altro
buffer senza switch di contesto (regola: with-current-buffer per agire,
buffer-local-value per sbirciare; primo argomento = SIMBOLO quotato);
`cl-remove-if-not` (famiglia di cl-remove/cl-find-if, non distruttivo;
equivalente moderno seq-filter — scelta di coerenza col file); la catena
dei degeneri regge da sola (process-live-p accetta nil); `and` ordinato
(condizione economica prima).

#### Spezzone 3 (→ 3-bis) — `emux--read-session` + `emux-switch-session`
- Completamento sui **nomi di HOST** (`mx`, non `*ssh:mx*`): unici tra le
  sessioni vive per l'idempotenza "un host, un buffer"; il marcatore li
  dà senza parsing.
- **Default = MRU diversa dal corrente** (dividendo dello spezzone 2):
  switch + RET rimbalza tra le ultime due sessioni — il `last-window` di
  tmux e l'idioma di `C-x b`, gratis. Degenere (unica sessione = la
  corrente): default su se stessa, RET innocuo.
- **Helper subito** in deroga ragionata alla regola delle tre (simmetria
  strutturale con `emux--read-host`, consumatori futuri in vista;
  argomento dello spezzone 10 step 3: interfacce di dialogo con
  contratto preciso).
Concetti: **DEF di `completing-read` — il gemello buono della lezione
9-bis**: minibuffer VUOTO, RET a vuoto restituisce DEF (ammesso anche
con REQUIRE-MATCH t: i due argomenti si conoscono), `M-n`
(next-history-element, "future history") lo porta nel minibuffer.
INITIAL per editare valori esistenti, DEF per proporre una scelta.
**`format-prompt`** (28+): l'annotazione "(default X)" è governata da
`minibuffer-default-prompt-format` dell'utente — scriverla a mano
ruberebbe la manopola; per questo l'helper vuole il prompt SENZA i due
punti (asimmetria con emux--read-host, dichiarata). **Lambda in un
`let*`** (prima volta): funzione locale legata come valore, chiamata con
funcall / passata a :key SENZA `#'` (è già un oggetto funzione);
fattorizza la proiezione buffer→nome che ricorreva tre volte; possibile
solo col lexical binding. `cl-find-if` con negazione nella lambda
(`:test-not` è deprecato); `or ... (car sessions)` per il degenere.
*Appunto utente su M-n risolto*: era un'incomprensione (andava provato
DENTRO il prompt del comando); metodo diagnostico registrato: `C-h k`
al prompt per vedere i binding stratificati del minibuffer.
**3-bis (da segnalazione utente)**: `pop-to-buffer` apriva una NUOVA
finestra se nessuna mostrava già la sessione. Per un comando "switch"
l'intento tmux è SOSTITUIRE la vista → **`pop-to-buffer-same-window`**:
dichiara "stessa finestra" ma passa dalla machinery di display-buffer.
Concetto: **gerarchia delle azioni di display** —
display-buffer-overriding-action > `display-buffer-alist` (utente) >
ACTION del chiamante (noi) > base-action > fallback: l'utente ci
scavalca sempre ("preferisco così" vs "faccio così e basta").
*Trade-off registrato dall'utente*: si perde il salto-alla-finestra-che-
già-la-mostra; documentato in docstring; chi lo rivuole ha la via
`display-buffer-reuse-window` in display-buffer-alist (la gerarchia sta
lì apposta). Porta chiusa, non murata.

#### Spezzone 4 — `emux--session-cycle` + next/previous
- **Perché NON l'ordine MRU per ciclare**: ciclare MODIFICA l'ordine su
  cui si cicla (ogni next riscrive la classifica → next×2 rimbalza tra
  le prime due, previous non è l'inverso di next). Serve un **ordine
  stabile**: scelto l'**alfabetico sul nome host** (stabile per
  costruzione, PREDICIBILE — meglio dell'ordine di creazione di tmux,
  che comunque non tracciamo: niente registro). Chi vuole la recente ha
  switch + RET.
- **next/prev da un buffer non-sessione → prima dell'anello** (non
  user-error): il gesto diventa anche "portami alle sessioni" da
  qualunque punto; un errore lì non protegge nessuno.
- **Un helper (OFFSET), due comandi gusci** con 1 e -1.
Concetti: **`sort` a keyword di Emacs 30**: NON distruttiva per default
(la storica `(sort seq pred)` rimonta i cons — bug classico; `:in-place
t` per chi vuole la vecchia semantica, dichiarandola) e porta `:key`;
qui la distruttività sarebbe stata lecita (lista fresca) ma "sicuro per
default" vince (principio di cl-remove e :copier nil, promosso a default
del linguaggio). **`mod` vs `%`** — il cuore dell'anello: mod segue il
segno del DIVISORE → `(mod -1 3)` = 2 (previous dalla prima → ultima),
mentre `(% -1 3)` = -1 romperebbe il giro all'indietro; circolarità
bidirezionale senza rami. `cl-position`: il "dove" di cl-find; qui il
default `eql` è GIUSTO senza :test (identità di oggetti buffer —
contrappunto dell'errore classico con le stringhe); il nil di "non
trovato" non è errore ma informazione (ramo "entra dall'inizio"). `nth`
O(n): irrilevante su una manciata di sessioni.
Proprietà verificate nei test: wraparound nei due versi, n-poi-p = fermo
(ciò che l'MRU non poteva dare), stabilità dell'anello dopo switch a
caso.

#### Spezzone 5 (5a + 5b) — politica di display
**Meccanismo: Strada B — `display-buffer-in-tab` come ACTION** di
pop-to-buffer (scartata la A, pilotare i comandi tab-bar a mano:
imperativo, fragile, FUORI dalla machinery → le regole utente non
potrebbero dire la loro). Restare al gradino "chiamante" della
gerarchia; la politica di emux è LETTERALMENTE quale ACTION passiamo —
un dato, non un ramo (stessa mossa dei backend). display-buffer-in-tab
è idempotente per costruzione: tab col nome esiste → selezionala; manca
→ creala.
**Centralizzazione: `emux--session-display`**, unico proprietario della
presentazione, tre consumatori. Firma `(buffer &optional navigating)`:
in `window` l'intento conta (aprire → può splittare; navigare → stessa
finestra), in `tab` i due intenti coincidono. Flag booleano (due soli
intenti; promuovibile a simbolo se ne emergesse un terzo).
**Nome della tab = nome logico della sessione** (`ssh:mx`), derivato dal
nome del BUFFER togliendo gli asterischi (non ricostruito dal marcatore:
cablerebbe "ssh:" in un helper che deve restare agnostico al
protocollo). Il contratto del 5-bis incassa il secondo dividendo, in
direzione inversa (là nome→buffer, qui buffer→nome). Unico anche con
RDP futuro (`rdp:mx` ≠ `ssh:mx`).
**5a — manopola + motore**: `defcustom emux-display-policy` (default
`window`) + helper, testati da `M-:` prima di toccare i comandi.
Concetti: **anatomia dell'ACTION** `(FUNZIONI . ALIST)` — lo stesso
formato che l'utente scrive in display-buffer-alist (impararlo da
chiamanti = saperlo da configuratori); terza vita del backquote
(struttura dati annidata con un solo punto caldo: quando la forma conta
più del calcolo, il backquote È la documentazione);
`string-remove-prefix`/`-suffix` (togli-se-c'è; niente regexp per
letterali — e `*` sarebbe pure un quantificatore da escapare); **`pcase`
scritto da noi** (prima volta): pattern `'simbolo` = confronto col
quotato, ramo-sentinella `other` (pattern variabile = else che lega) con
`user-error` — una defcustom è scrivibile da chiunque con un typo, il
fallback silenzioso sarebbe feedback invisibile; **niente require di
tab-bar**: display-buffer-in-tab è autoloaded da un builtin (il require
pigro regalato dall'infrastruttura; il byte-compiler la conosce, niente
declare-function — differenza da eat, pacchetto esterno).
**5b — migrazione dei tre comandi**, uno alla volta: switch (navigating
t), next/prev (navigating t; la divisione del lavoro si compone: cycle
decide QUALE, display decide DOVE E COME), connect (**due innesti**,
riattacco e coronamento della pipeline, entrambi con intento APERTURA —
anche il riattacco: "voglio quella sessione davanti", non un passo di
navigazione). In tab connect è idempotente DUE volte — sul buffer (un
host, un buffer) e sulla tab (una sessione, una tab) — e le due
idempotenze poggiano sulla STESSA stringa: il nome logico del 5-bis.
A fine 5b: NESSUNA chiamata diretta a pop-to-buffer* nei comandi.

#### INCIDENTE "ultima tab" (istruttivo, chiuso)
Sintomo: `tab-close: Attempt to delete the sole tab in a frame`.
Nessun bug: **una tab È una window configuration**, e lo stato corrente
del frame È una tab, sempre — "creare la prima tab" ne crea una SECONDA;
un frame ha per costruzione almeno una tab, chiudere l'ultima
significherebbe un frame senza stato. tmux qui DIVERGE (chiudere
l'ultima window uccide la sessione: la window è costitutiva; in Emacs il
frame preesiste alle tab). Famiglia della lezione 5-ter: frame, tab,
finestre e buffer = QUATTRO cicli di vita distinti.
*Errore mio corretto*: avevo detto che con una sola tab la barra sparisce
da sé — FALSO: il default di `tab-bar-show` è `t`; il comportamento
esiste con `tab-bar-show` a `1` (personalizzazione utente, territorio di
tab-bar: emux indica, non tocca — principio 4-ter). Con tab-bar-show a 1
la modalità tab di emux diventa elegante (barra solo con 2+ sessioni).
Saldo: riga su tab-bar-show aggiunta alla docstring di
emux-display-policy nella chiusura dello step.
*Osservazione utente durante lo stato intermedio della migrazione*
(next/prev non ancora migrati, testati in tab): i nomi delle tab
assegnati esplicitamente (il nostro tab-name) sono **appiccicosi** — non
seguono più il buffer corrente (di default sono dinamici). Feature per
il design (la tab È "la casa di ssh:mx"); il quadro incoerente
(tab `ssh:alpha` col buffer di beta) era il vecchio next che infilava
buffer scavalcando la machinery — curato dalla migrazione stessa: i
comandi non portano il buffer da te, portano te dalla tab del buffer.

#### Spezzone 6 — keymap
**Layout** (eco tmux): `c` connect (il c di tmux crea), `s` switch, `n`/
`p` next/previous, più i CRUD inclusi (`a` add, `e` edit, `d` delete —
punto d'ingresso del pacchetto; `d`≠detach di tmux: il nostro detach è
chiudere il client, roadmap 7; alternativa `k` discussa e non adottata).
**`emux-repeat-map` con `:repeat t`, SOLO n/p**: con `repeat-mode`
attivo, dopo il primo next/prev i tasti restano attivi nudi (n n p n...);
ripetere connect o delete non ha senso, e una repeat map larga cattura
tasti a tradimento (contro-test: dopo `C-c e c`, `n` nudo self-inserta
nel terminale). Stratificazione per la terza volta nello step: noi
marchiamo la mappa, l'utente decide se attivare repeat-mode.
**Nessun tasto globale**: la docstring mostra l'aggancio consigliato
`(keymap-global-set "C-c e" emux-command-map)`.
Concetti: **`defvar-keymap`** (29+) vs liturgia
make-sparse-keymap/define-key; tasti in sintassi kbd VALIDATI alla
definizione; una keymap è un normale oggetto Lisp legato a una variabile
→ l'aggancio passa la variabile senza quote (lega il VALORE); un prefix
key non è un meccanismo a parte: è un tasto legato a una keymap invece
che a un comando (C-x stesso funziona così). `:repeat t` mette la
proprietà `repeat-map` sul SIMBOLO di ogni comando della mappa (i
comandi restano ignari — fratello concettuale di add-function:
comportamento attaccato dall'esterno). Markup ``\\`c'`` nelle docstring
per i tasti (28+).

#### Chiusura dello step
- **Cookie `;;;###autoload` su tutti e 7 i comandi** (i 3 CRUD aggiunti
  dall'utente: debito dello step 4 SALDATO; verificata la copertura:
  tutti i comandi, nessun helper `--` — sarebbero rumore).
- **Docstring di `emux-display-policy` estesa** con la riga su
  tab-bar-show (il costo estetico del default, con la via d'uscita
  accanto, link navigabile via backquote+apice).
- checkdoc e byte-compile a freddo puliti (prima compilazione con
  defvar-keymap e sort a keyword: nessun warning), `rm emux.elc`.

#### Struttura del file emux.el a fine step 5
Come a fine step 4, con queste evoluzioni:
- Sezione 9 rinominata «Sessioni: strumenti comuni ai backend» e
  arricchita: `defcustom emux-display-policy` in testa, poi
  `emux--session-notify-on-exit`, `emux--session-quit-window-on-exit`,
  `defvar-local emux-session-host-name`, `emux--session-mark`,
  `emux--session-buffers`, `emux--read-session` (NB: sta qui e non in
  «Input dal minibuffer»), `emux--session-cycle`,
  `emux--session-display`.
- Nuova sezione «Keymap» (tra i wrapper di sessione e i comandi):
  `emux-repeat-map`, `emux-command-map`.
- Sezione «Comandi»: `emux-connect-ssh`, `emux-host-add`,
  `emux-host-edit`, `emux-host-delete`, `emux-switch-session`,
  `emux-next-session`, `emux-previous-session` — tutti con autoload;
  la presentazione passa ovunque da `emux--session-display`.

#### Debiti e possibilità future registrati (step 5)
- **Tab orfana alla morte della sessione** (modalità tab): quit-restore-
  window congeda la finestra, ma se è l'unica della tab la tab resta,
  vuota di senso. Cura possibile: wrapper di sentinella che chiuda la
  tab su uscita pulita (con le sue insidie: split utente dentro la tab).
  Fuori perimetro per ora — prima l'uso reale, poi la politica (metodo
  5-ter).
- Eventuale terzo intento di `emux--session-display` → flag booleano da
  promuovere a simbolo (modifica locale).
- Eventuale `emux-list-sessions` (tabulated-list) come estensione.
- Eventuale argomento opzionale a `emux--session-buffers` per elencare
  anche i post-mortem (uso diagnostico).
- Ereditati dallo step 4 e ancora aperti: `eat-kill-buffer-on-exit` nil
  buffer-locale nei buffer emux (opzione b); ammorbidimento della
  politica finestre su "finished"; suggerimento automatico della cura su
  fallimento da raffica di chiavi; pop-to-buffer su morte precoce.
  (Il debito autoload dei CRUD è SALDATO in questo step.)

## Roadmap complessiva
1. ✅ Scheletro del pacchetto
2. ✅ Design: strutture dati + scelta backend terminale
3. ✅ Catalogo host proprietario (formato .eld) con CRUD interattivo
   completo (add/edit/delete), helper di lettura riusabili,
   verifica checkdoc/byte-compile superata
4. ✅ Apertura sessione SSH: `emux--ssh-command` pura (isolamento
   config+agent, extra-options sovrane), one-shot (semantica 1),
   astrazione `cl-defgeneric` con contratto a 4 obblighi, backend eat
   (require pigro, declare-function), notifica di fine sessione e
   rilascio finestra su uscita pulita (add-function :before/:after
   sulla sentinella), comando idempotente `emux-connect-ssh`
   (interactive con spec, autoload); incidente ssh diagnosticato e
   chiuso (agent gcr + file di default + MaxAuthTries +
   PerSourcePenalties); checkdoc/byte-compile a freddo puliti
5. ✅ Layout stile tmux: marcatore buffer-locale
   `emux-session-host-name` + `emux--session-mark` (chiave, non
   struct), enumeratore `emux--session-buffers` (marcatore + processo
   vivo, ordine MRU dichiarato), `emux-switch-session` con default MRU
   (DEF di completing-read, format-prompt) e
   pop-to-buffer-same-window (3-bis, gerarchia delle azioni),
   anello alfabetico stabile `emux--session-cycle` (sort a keyword di
   Emacs 30, mod vs %) con `emux-next/previous-session`, politica di
   display centralizzata `emux-display-policy` (default window) +
   `emux--session-display` (display-buffer-in-tab come ACTION, nome
   tab = nome logico), keymap `emux-command-map` + `emux-repeat-map`
   (:repeat su n/p, nessun tasto globale), autoload su tutti i
   comandi; incidenti istruttivi: finestra di switch, ultima tab
   (tab = window configuration, tab-bar-show); debito registrato:
   tab orfana alla morte della sessione; checkdoc/byte-compile a
   freddo puliti
6. Integrazione TRAMP: dired/find-file sui server remoti (da costruire noi
   i nomi `/ssh:user@host#port:` a partire dalle struct: TRAMP non conosce
   il nostro catalogo; il marcatore `emux-session-host-name` è la chiave
   per risalire all'host della sessione corrente)
7. Documentazione workflow daemon (attach/detach)
8. RDP: gestione xfreerdp come processo esterno (accantonato finché
   l'utente non lo richiederà; probabile slot `type` nella struct;
   nomi già decisi per simmetria: `emux--rdp-command`,
   `emux-connect-rdp`)

## Nota operativa
A fine di ogni chat/step: aggiornare questo file e la copia di `emux.el`
nella knowledge del progetto.
