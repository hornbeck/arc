; scheme48
; ,open tables sockets extended-ports c-system-function ascii i/o-internal 
; ,open posix-files handle random pp simple-conditions

; to do:
; select, perhaps with threads, or pltt events
; check argument count for complex arguments

; refs.arc, first 300 lines of x, total CPU time including startup. on powerbook.
; scheme48: 31.944u 0.518s 2:13.65 24.2%    0+0k 5+7io 0pf+0w
; mzscheme: 16.425u 0.489s 0:52.61 32.1%    0+0k 26+22io 0pf+0w

; dynamic creation of local variables with =
;   can you create globals inside a procedure? 
;   does action of = depend on whether, at run time,
;     the variable has a global definition?
;   what's the scope of such a variable?
;   though a.lisp seems to create a global, not a local!
; run-time expansion of macros
; how do I know if something is a macro at compile time?
; macros have lexical scope. so how do i know if a lexical
;   variable is going to be bound to a procedure? or to a macro?
; what is annotate doing to symbols?
; tests.arc implies that '(a b) produces a mutable list
;   so (fn () '(a)) produces a list that can be modified,
;     and future calls will reflect the modifications
;   oy. clisp works this way too.
;   it's not that easy to simulate this.
; what is this? (def foo1 (x (o y x)) (list x y))

; it's not clear I translate NILs in the outputs of macros correctly.
;   I translate (NIL . NIL) to ('NIL . '())
; I use Scheme apply to call macros.
;   Scheme apply demands a '()-terminated list.
;   most macros have a . body argument.
;   so body is '()-terminated, not NIL-terminated.
;   solution: ar-false? knows about '()
; this doesn't work, since var isn't a variable name:
; (mac or args
;   (and args
;        (let var (tag 'symbol (list 'or))
;          (list 'let var (car args)
;                (list 'if var var (cons 'or (cdr args)))))))

(module ac mzscheme

(provide (all-defined))
(require (lib "port.ss"))
(require (lib "process.ss"))
(require (lib "pretty.ss"))

; compile an Arc expression into a Scheme expression,
; both represented as s-expressions.
; env is a list of lexically bound variables, which we
; need in order to decide whether set should create a global.

(define (ac s env)
  (let ((head (xcar s)))
    (cond ((string? s) (string-copy s))  ; to avoid immutable strings
          ((literal? s) s)
          ((eqv? s 'nil) (list 'quote 'nil))
          ((ssyntax? s) (ac (expand-ssyntax s) env))
          ((symbol? s) (ac-var-ref s env))
          ((ssyntax? head) (ac (cons (expand-ssyntax head) (cdr s)) env))
          ((eq? head 'quote) (list 'quote (ac-niltree (cadr s))))
          ((eq? head 'quasiquote) (ac-qq (cadr s) env))
          ((eq? head 'if) (ac-if (cdr s) env))
          ((eq? head 'fn) (ac-fn (cadr s) (cddr s) env))
          ((eq? head 'set) (ac-set (cdr s) env))
          ; this line could be removed without changing semantics
          ((eq? (xcar head) 'compose) (ac (decompose (cdar s) (cdr s)) env))
          ((pair? s) (ac-call (car s) (cdr s) env))
          (#t (err "Bad object in expression" s)))))

(define (literal? x)
  (or (boolean? x)
      (char? x)
      (string? x)
      (number? x)
      (eq? x '())))

(define (ssyntax? x)
  (and (symbol? x)
       (not (or (eqv? x '+) (eqv? x '++)))
       (let ((name (symbol->string x)))
         (has-ssyntax-char? name (- (string-length name) 1)))))

(define (has-ssyntax-char? string i)
  (and (>= i 0)
       (or (let ((c (string-ref string i)))
             (or (eqv? c #\:) (eqv? c #\~)))
           (has-ssyntax-char? string (- i 1)))))

(define (read-from-string str)
  (let ((port (open-input-string str)))
    (let ((val (read port)))
      (close-input-port port)
      val)))

(define (expand-ssyntax sym)
  (let ((elts (map (lambda (tok)
                     (if (eqv? (car tok) #\~)
                         `(complement ,(chars->value (cdr tok)))
                         (chars->value tok)))
                   (tokens #\: (symbol->chars sym) '() '()))))
    (if (null? (cdr elts))
        (car elts)
        (cons 'compose elts))))

(define (symbol->chars x) (string->list (symbol->string x)))

(define (chars->value chars) (read-from-string (list->string chars)))

; result will contain || if separator at end of symbol; could use
; that to mean something

(define (tokens separator source token acc)
  (cond ((null? source)
         (reverse (cons (reverse token) acc)))
        ((eqv? (car source) separator)
         (tokens separator
                 (cdr source)
                 '()
                 (cons (reverse token) acc)))
        (#t
         (tokens separator
                 (cdr source)
                 (cons (car source) token)
                 acc))))

; Purely an optimization.  Could in principle do it with a preprocessor
; instead of adding a line to ac, but only want to do it for evaluated
; subtrees, and much easier to figure those out in ac.

(define (decompose fns args)
  (cond ((null? fns) `((fn vals (car vals)) ,@args))
        ((null? (cdr fns)) (cons (car fns) args))
        (#t (list (car fns) (decompose (cdr fns) args)))))


(define (ac-global-name s)
  (string->symbol (string-append "_" (symbol->string s))))

(define (ac-var-ref s env)
  (if (lex? s env)
      s
      (ac-global-name s)))

; quasiquote

(define (ac-qq args env)
  (list 'quasiquote (ac-qq1 1 args env)))

; process the argument of a quasiquote. keep track of
; depth of nesting. handle unquote only at top level (level = 1).
; complete form, e.g. x or (fn x) or (unquote (fn x))
(define (ac-qq1 level x env)
  (cond ((= level 0)
         (ac x env))
        ((eqv? (xcar x) 'unquote)
         (list 'unquote (ac-qq1 (- level 1) (cadr x) env)))
        ((and (eqv? (xcar x) 'unquote-splicing) (= level 1))
         (list 'unquote-splicing
               (list 'ar-nil-terminate (ac-qq1 (- level 1) (cadr x) env))))
        ((eqv? (xcar x) 'quasiquote)
         (list 'quasiquote (ac-qq1 (+ level 1) (cadr x) env)))
        ((pair? x)
         (map (lambda (x) (ac-qq1 level x env)) x))
        (#t x)))

; (if) -> nil
; (if x) -> x
; (if t a ...) -> a
; (if nil a b) -> b
; (if nil a b c) -> (if b c)

(define (ac-if args env)
  (cond ((null? args) ''nil)
        ((null? (cdr args)) (ac (car args) env))
        (#t `(if (not (ar-false? ,(ac (car args) env)))
;(not (eq? 'nil ,(ac (car args) env)))
                 ,(ac (cadr args) env)
                 ,(ac-if (cddr args) env)))))

; translate fn directly into a lambda if it has ordinary
; parameters, otherwise use a rest parameter and parse it.
(define (ac-fn args body env)
  (if (ac-complex-args? args)
      (ac-complex-fn args body env)
      `(lambda ,(let ((a (ac-denil args))) (if (eqv? a 'nil) '() a))
         ,@(ac-body* body (append (ac-arglist args) env)))))

; does an fn arg list use optional parameters or destructuring?
; a rest parameter is not complex
(define (ac-complex-args? args)
  (cond ((eqv? args '()) #f)
        ((symbol? args) #f)
        ((symbol? (xcar args))
         (ac-complex-args? (cdr args)))
        (#t #t)))

; translate a fn with optional or destructuring args
; (fn (x (o y x) (o z 21) (x1 x2) . rest) ...)
; arguments in top-level list are mandatory (unless optional),
; but it's OK for parts of a list you're destructuring to
; be missing.
(define (ac-complex-fn args body env)
  (let* ((ra (ar-gensym))
         (z (ac-complex-args args env ra #t)))
    `(lambda ,ra
       (let* ,z
         ,@(ac-body* body (append (ac-complex-getargs z) env))))))

; returns a list of two-element lists, first is variable name,
; second is (compiled) expression. to be used in a let.
; caller should extract variables and add to env.
; ra is the rest argument to the fn.
; is-params indicates that args are function arguments
;   (not destructuring), so they must be passed or be optional.
(define (ac-complex-args args env ra is-params)
  (cond ((or (eqv? args '()) (eqv? args 'nil)) '())
        ((symbol? args) (list (list args ra)))
        ((pair? args)
         (let* ((x (if (and (pair? (car args)) (eqv? (caar args) 'o))
                       (ac-complex-opt (cadar args) 
                                       (if (pair? (cddar args))
                                           (caddar args) 
                                           'nil)
                                       env 
                                       ra)
                       (ac-complex-args
                        (car args)
                        env
                        (if is-params
                            `(car ,ra)
                            `(ar-xcar ,ra))
                        #f)))
                (xa (ac-complex-getargs x)))
           (append x (ac-complex-args (cdr args)
                                      (append xa env)
                                      `(ar-xcdr ,ra)
                                      is-params))))
        (#t (err "Can't understand fn arg list" args))))

; (car ra) is the argument
; so it's not present if ra is nil or '()
(define (ac-complex-opt var expr env ra)
  (list (list var `(if (pair? ,ra) (car ,ra) ,(ac expr env)))))

; extract list of variables from list of two-element lists.
(define (ac-complex-getargs a)
  (map (lambda (x) (car x)) a))

; (a b . c) -> (a b c)
; a -> (a)
(define (ac-arglist a)
  (cond ((null? a) '())
        ((symbol? a) (list a))
        ((symbol? (cdr a)) (list (car a) (cdr a)))
        (#t (cons (car a) (ac-arglist (cdr a))))))

(define (ac-body body env)
  (map (lambda (x) (ac x env)) body))

;; like ac-body, but spits out a nil expression if empty
(define (ac-body* body env)
  (if (null? body)
      (list (list 'quote 'nil))
      (ac-body body env)))

; (set v1 expr1 v2 expr2 ...)

(define (ac-set x env)
  `(begin ,@(ac-setn x env)))

(define (ac-setn x env)
  (if (null? x)
      '()
      (cons (ac-set1 (ac-macex (car x)) (ac (cadr x) env) env)
            (ac-setn (cddr x) env))))

; = replaced by set, which is only for vars
; = now defined in arc (is it?)
; name is to cause fns to have their arc names for debugging

(define (ac-set1 a b env)
  (if (symbol? a)
      (let ((name (string->symbol (string-append " " (symbol->string a)))))
        (list 'let `((,name ,b))
               (cond ((eqv? a 'nil) (err "Can't rebind nil"))
                     ((eqv? a 't) (err "Can't rebind t"))
                     ((lex? a env) `(set! ,a ,name))
                     (#t `(namespace-set-variable-value! ',(ac-global-name a) 
                                                         ,name)))
               name))
      (err "First arg to set must be a symbol" a)))

; compile a function call
; special cases for speed, to avoid compiled output like
;   (ar-apply _pr (list 1 2))
; which results in 1/2 the CPU time going to GC. Instead:
;   (ar-funcall2 _pr 1 2)
(define (ac-call fn args env)
  (let ((macfn (ac-macro? fn)))
    (if macfn
      (ac-mac-call macfn args env)
      (let ((afn (ac fn env))
            (aargs (map (lambda (x) (ac x env)) args))
            (nargs (length args)))
        (cond 
          ((eqv? (xcar fn) 'fn)
           `(,afn ,@aargs))
          ((and (>= nargs 0) (<= nargs 4))
           `(,(string->symbol (string-append "ar-funcall" (number->string nargs)))
              ,afn ,@aargs))
          (#t
           `(ar-apply ,afn (list ,@aargs))))))))

(define (ac-mac-call m args env)
  (let ((x1 (apply m (map ac-niltree args))))
    (let ((x2 (ac (ac-denil x1) env)))
      x2)))

; returns #f or the macro function

(define (ac-macro? fn)
  (if (symbol? fn)
      (let ((v (namespace-variable-value (ac-global-name fn) 
                                         #t 
                                         (lambda () #f))))
        (if (and v
                 (ar-tagged? v)
                 (eq? (ar-type v) 'mac))
            (ar-rep v)
            #f))
      #f))

; macroexpand the outer call of a form as much as possible

(define (ac-macex e . once)
  (let ((m (ac-macro? (xcar e))))
    (if m
      (let ((expansion (ac-denil (apply m (map ac-niltree (cdr e))))))
        (if (null? once) (ac-macex expansion) expansion))
      e)))

; macros return Arc lists, ending with NIL.
; but the Arc compiler expects Scheme lists, ending with '().
; what to do with (is x nil . nil) ?
;   the first nil ought to be replaced with 'NIL
;   the second with '()
; so the rule is: NIL in the car -> 'NIL, NIL in the cdr -> '().
;   NIL by itself -> NIL

(define (ac-denil x)
  (cond ((pair? x) (cons (ac-denil-car (car x)) (ac-denil-cdr (cdr x))))
        (#t x)))

(define (ac-denil-car x)
  (if (eq? x 'nil)
      'nil
      (ac-denil x)))

(define (ac-denil-cdr x)
  (if (eq? x 'nil)
      '()
      (ac-denil x)))

; is v lexically bound?
(define (lex? v env)
  (memq v env))

(define (xcar x)
  (and (pair? x) (car x)))

; #f and '() -> nil for a whole quoted list/tree.

(define (ac-niltree x)
  (cond ((pair? x) (cons (ac-niltree (car x)) (ac-niltree (cdr x))))
        ((or (eq? x #f) (eq? x '())) 'nil)
        (#t x)))

;(define (err msg . args)
;  (display msg)
;  (map (lambda (a) (display " ") (write a))  args)
;  (newline)
;  (xxundefined))

(define err error)  ; eli says need to remove xxundefined for speed

; run-time primitive procedures

(define (xdef a b)
  (namespace-set-variable-value! (ac-global-name a) b)
  b)

(define fn-signatures (make-hash-table 'equal))

; This is a replacement for xdef that stores opeator signatures.
; Haven't started using it yet.

(define (odef a parms b)
  (namespace-set-variable-value! (ac-global-name a) b)
  (hash-table-put! fn-signatures a (list parms))
  b)

(xdef 'sig fn-signatures)

; versions of car and cdr for parsing arguments for optional
; parameters, that yield nil for nil. maybe we should use
; full Arc car and cdr, so we can destructure more things

(define (ar-xcar x)
  (if (or (eqv? x 'nil) (eqv? x '()))
      'nil
      (car x)))
      
(define (ar-xcdr x)
  (if (or (eqv? x 'nil) (eqv? x '()))
      'nil
      (cdr x)))

; convert #f from a Scheme predicate to NIL.

(define (ar-nill x)
  (if (or (eq? x '()) (eq? x #f))
      'nil
      x))

; definition of falseness for Arc if.
; must include '() since sometimes Arc functions see
; Scheme lists (e.g. . body of a macro).

(define (ar-false? x)
  (or (eq? x 'nil) (eq? x '()) (eq? x #f)))

#|
   (if (eq? x 'nil) #t
      (if (eq? x '()) #t
          (not x)))
|#

; call a function or perform an array ref, hash ref, &c

; Non-fn donstants in functional position are valuable real estate, so
; should figure out the best way to exploit it.

(define (ar-apply fn args)
  (cond ((procedure? fn) (apply fn args))
        ((pair? fn) (list-ref fn (car args)))
        ((string? fn) (string-ref fn (car args)))
        ((hash-table? fn) (ar-nill (hash-table-get fn (car args) #f)))
; experiment: means e.g. [1] is a constant fn
;       ((or (number? fn) (symbol? fn)) fn)
; another possibility: constant in functional pos means it gets 
; passed to the first arg, i.e. ('kids item) means (item 'kids).
        (#t (err "Function call on inappropriate object" fn args))))

(xdef 'apply (lambda (fn . args)
               (ar-apply fn (ar-apply-args args))))

; special cases of ar-apply for speed and to avoid consing arg lists
(define (ar-funcall0 fn)
  (if (procedure? fn)
      (fn)
      (ar-apply fn (list))))

(define (ar-funcall1 fn arg1)
  (if (procedure? fn)
      (fn arg1)
      (ar-apply fn (list arg1))))

(define (ar-funcall2 fn arg1 arg2)
  (if (procedure? fn)
      (fn arg1 arg2)
      (ar-apply fn (list arg1 arg2))))

(define (ar-funcall3 fn arg1 arg2 arg3)
  (if (procedure? fn)
      (fn arg1 arg2 arg3)
      (ar-apply fn (list arg1 arg2 arg3))))

(define (ar-funcall4 fn arg1 arg2 arg3 arg4)
  (if (procedure? fn)
      (fn arg1 arg2 arg3 arg4)
      (ar-apply fn (list arg1 arg2 arg3 arg4))))

; replace the nil at the end of a list with a '()

(define (ar-nil-terminate l)
  (if (or (eqv? l '()) (eqv? l 'nil))
      '()
      (cons (car l) (ar-nil-terminate (cdr l)))))

; turn the arguments to Arc apply into a list.
; if you call (apply fn 1 2 '(3 4))
; then args is '(1 2 (3 4 . nil) . ())
; that is, the main list is a scheme list.
; and we should return '(1 2 3 4 . ())
; was once (apply apply list (ac-denil args))
; but that didn't work for (apply fn nil)

(define (ar-apply-args args)
  (cond ((null? args) '())
        ((null? (cdr args)) (ar-nil-terminate (car args)))
        (#t (cons (car args) (ar-apply-args (cdr args))))))

(xdef 'cons cons)

(xdef 'car (lambda (x)
             (cond ((pair? x)     (car x))
                   ((eqv? x 'nil) 'nil)
                   ((eqv? x '())  'nil)
                   (#t            (err "Can't take car of" x)))))

(xdef 'cdr (lambda (x)
             (cond ((pair? x)     (cdr x))
                   ((eqv? x 'nil) 'nil)
                   ((eqv? x '())  'nil)
                   (#t            (err "Can't take cdr of" x)))))

; reduce? 

(define (pairwise pred args base)
  (let ((n (length args)))
    (cond ((< n 2) base)
          ((= n 2) (apply pred args))
          (#t (and (pred (car args) (cadr args))
                   (pairwise pred (cdr args) base))))))

; not quite right, because behavior of underlying eqv unspecified
; in many cases according to r5rs
; do we really want is to ret t for distinct strings?

(xdef 'is (lambda args
            (if (or (all (lambda (a) (eqv? (car args) a)) (cdr args))
                    (and (all string? args)
                         (apply string=? args))
                    (all ar-false? args))
                't 'nil)))

(xdef 'err err)
(xdef 'nil 'nil)
(xdef 't   't)

(define (all test seq)
  (or (null? seq) 
      (and (test (car seq)) (all test (cdr seq)))))

; rather strictly excludes ()

(define (arc-list? x) (or (pair? x) (eqv? x 'nil)))
      
; generic +: strings, lists, numbers.
; problem with generic +: what to return when no args?
; could even coerce based on type of first arg...

(xdef '+ (lambda args
           (cond ((null? args) 0)
                 ((all string? args) 
                  (apply string-append args))
                 ((all arc-list? args) 
                  (ac-niltree (apply append (map ar-nil-terminate args))))
                 (#t (apply + args)))))

(xdef '- -)
(xdef '* *)
(xdef '/ /)
(xdef 'mod modulo)
(xdef 'expt expt)
(xdef 'sqrt sqrt)

; generic comparison

(define (arc> . args)
  (cond ((all number? args) (apply > args))
        ((all string? args) (pairwise string>? args #f))
        ((all symbol? args) (pairwise (lambda (x y)
                                        (string>? (symbol->string x) 
                                                  (symbol->string y)))
                                      args
                                      #f))
        ((all char?   args) (pairwise char>?   args #f))
        (#t                 (apply > args))))
(xdef '>  (lambda args (if (apply arc> args) 't 'nil)))

(define (arc< . args)
  (cond ((all number? args) (apply < args))
        ((all string? args) (pairwise string<? args #f))
        ((all symbol? args) (pairwise (lambda (x y)
                                        (string<? (symbol->string x) 
                                                  (symbol->string y)))
                                      args
                                      #f))
        ((all char?   args) (pairwise char<?   args #f))
        (#t                 (apply < args))))
(xdef '<  (lambda args (if (apply arc< args) 't 'nil)))

(xdef 'len (lambda (x)
             (cond ((string? x) (string-length x))
                   ((hash-table? x) (hash-table-count x))
                   (#t (length (ar-nil-terminate x))))))

(define (ar-tagged? x)
  (and (vector? x) (eq? (vector-ref x 0) 'tagged)))

(define (ar-tag type rep)
  (cond ((eqv? (ar-type rep) type) rep)
        (#t (vector 'tagged type rep))))
(xdef 'annotate ar-tag)

; (type nil) -> sym

(define (ar-type x)
  (cond ((ar-tagged? x)     (vector-ref x 1))
        ((pair? x)          'cons)
        ((symbol? x)        'sym)
        ((null? x)          'sym)
        ((procedure? x)     'fn)
        ((char? x)          'char)
        ((string? x)        'string)
        ((integer? x)       'int)
        ((number? x)        'num)     ; unsure about this
        ((hash-table? x)    'table)
        ((output-port? x)   'output)
        ((input-port? x)    'input)
        ((tcp-listener? x)  'socket)
        ((exn? x)           'exception)
        (#t                 (err "Type: unknown type" x))))
(xdef 'type ar-type)

(define (ar-rep x)
  (if (ar-tagged? x)
      (vector-ref x 2)
      x))
(xdef 'rep ar-rep)

; currently rather a joke: returns interned symbols

(define ar-gensym-count 0)
(define (ar-gensym)
  (set! ar-gensym-count (+ ar-gensym-count 1))
  (string->symbol (string-append "gs" (number->string ar-gensym-count))))
(xdef 'uniq ar-gensym)

(xdef 'ccc call-with-current-continuation)

(xdef 'infile  open-input-file)
(xdef 'outfile (lambda (f . args) 
                 (open-output-file f 
                                   'text
                                   (if (equal? args '(append))
                                       'append
                                       'truncate))))

(xdef 'instring  open-input-string)
(xdef 'outstring open-output-string)

; use as general fn for looking inside things

(xdef 'inside get-output-string)

(xdef 'close (lambda (p)
               (cond ((input-port? p)   (close-input-port p))
                     ((output-port? p)  (close-output-port p))
                     ((tcp-listener? p) (tcp-close p))
                     (#t (err "Can't close " p)))
               'nil))

(xdef 'stdout current-output-port)  ; should be a vars
(xdef 'stdin  current-input-port) 
(xdef 'stderr current-error-port)

(xdef 'call-w/stdout
      (lambda (port thunk)
        (parameterize ((current-output-port port)) (thunk))))

(xdef 'call-w/stdin
      (lambda (port thunk)
        (parameterize ((current-input-port port)) (thunk))))

; (readc stream)
; nil stream means stdout
; returns nil on eof

(xdef 'readc (lambda (str) 
               (let ((p (if (ar-false? str)
                            (current-input-port)
                            str)))
                 (let ((c (read-char p)))
                   (if (eof-object? c) 'nil c)))))

(xdef 'readb (lambda (str)
               (let ((p (if (ar-false? str)
                            (current-input-port)
                            str)))
                 (let ((c (read-byte p)))
                   (if (eof-object? c) 'nil c)))))

(xdef 'peekc (lambda (str) 
               (let ((p (if (ar-false? str)
                            (current-input-port)
                            str)))
                 (let ((c (peek-char p)))
                   (if (eof-object? c) 'nil c)))))

(xdef 'writec (lambda (c . args) 
                (write-char c 
                            (if (pair? args) 
                                (car args) 
                                (current-output-port)))
                c))

(xdef 'writeb (lambda (b . args) 
                (write-byte b 
                            (if (pair? args) 
                                (car args) 
                                (current-output-port)))
                b))

(xdef 'write (lambda args
               (if (pair? args)
                   (write (ac-denil (car args))
                          (if (pair? (cdr args))
                              (cadr args)
                              (current-output-port))))
               (flush-output)
               'nil))

(xdef 'disp (lambda args
              (if (pair? args)
                  (display (ac-denil (car args)) 
                           (if (pair? (cdr args)) 
                               (cadr args)
                               (current-output-port))))
              (flush-output)
              'nil))

; sread = scheme read. eventually replace by writing read

(xdef 'sread (lambda (p eof)
               (let ((expr (read p)))
                 (if (eof-object? expr) eof expr))))

; these work in PLT but not scheme48

(define char->ascii char->integer)
(define ascii->char integer->char)

(xdef 'coerce (lambda (x type . args)
                (cond 
                  ((ar-tagged? x) (err "Can't coerce annotated object"))
                  ((eqv? type (ar-type x)) x)

                  ((char? x)      (case type
                                    ((int)    (char->ascii x))
                                    ((string) (string x))
                                    ((sym)    (string->symbol (string x)))
                                    (else     (err "Can't coerce" x type))))
                  ((integer? x)   (case type
                                    ((char)   (ascii->char x))
                                    ((string) (apply number->string x args))
                                    (else     (err "Can't coerce" x type))))
                  ((number? x)    (case type
                                    ((int)    (round x))
                                    ((char)   (ascii->char (round x)))
                                    ((string) (apply number->string x args))
                                    (else     (err "Can't coerce" x type))))
                  ((string? x)    (case type
                                    ((sym)    (string->symbol x))
                                    ((cons)   (ac-niltree (string->list x)))
                                    ((int)    (or (apply string->number x args)
                                                  (err "Can't coerce" x type)))
                                    (else     (err "Can't coerce" x type))))
                  ((pair? x)      (case type
                                    ((string) (list->string
                                               (ar-nil-terminate x)))   
                                    (else     (err "Can't coerce" x type))))
                  ((eqv? x 'nil)  (case type
                                    ((string) "")
                                    (else     (err "Can't coerce" x type))))
                  ((symbol? x)    (case type 
                                    ((string) (symbol->string x))
                                    (else     (err "Can't coerce" x type))))
                  (#t             x))))

(xdef 'open-socket  (lambda (num) (tcp-listen num 50 #t))) 

; the 2050 means http requests currently capped at 2 meg
; http://list.cs.brown.edu/pipermail/plt-scheme/2005-August/009414.html

(xdef 'socket-accept (lambda (s)
                       (call-with-values
                         (lambda () (tcp-accept s))
                         (lambda (in out)
                           (list (make-limited-input-port in 100000 #t)
                                 out
                                 (let-values (((us them) (tcp-addresses out)))
                                   them))))))

(xdef 'thread thread)
(xdef 'kill-thread kill-thread)
(xdef 'break-thread break-thread)

(define (wrapnil f) (lambda args (apply f args) 'nil))

(xdef 'sleep (wrapnil sleep))

; Will system "execute" a half-finished string if thread killed
; in the middle of generating it?  

(xdef 'system (wrapnil system))

(xdef 'pipe-from (lambda (cmd)
                   (let ((tf (ar-tmpname)))
                     (system (string-append cmd " > " tf))
                     (let ((str (open-input-file tf)))
                       (system (string-append "rm -f " tf))
                       str))))
                   
(define (ar-tmpname)
  (call-with-input-file "/dev/urandom"
    (lambda (rstr)
      (do ((s "/tmp/")
           (c (read-char rstr) (read-char rstr))
           (i 0 (+ i 1)))
          ((>= i 16) s)
        (set! s (string-append s
                               (string
                                 (integer->char
                                   (+ (char->integer #\a)
                                      (modulo
                                        (char->integer (read-char rstr))
                                        26))))))))))

; PLT scheme provides only eq? and equal? hash tables,
; we need the latter for strings.

(xdef 'table (lambda () (make-hash-table 'equal)))

;(xdef 'table (lambda args
;               (fill-table (make-hash-table 'equal) 
;                           (if (pair? args) (ac-denil (car args)) '()))))
                   
(define (fill-table h pairs)
  (if (eq? pairs '())
      h
      (let ((pair (car pairs)))
        (begin (hash-table-put! h (car pair) (cadr pair))
               (fill-table h (cdr pairs))))))

(xdef 'maptable (lambda (fn table)               ; arg is (fn (key value) ...)
                  (hash-table-for-each table fn)
                  table))

(xdef 'protect (lambda (during after)
                  (dynamic-wind (lambda () #t) during after)))

; need to use a better seed

(xdef 'rand random)

(xdef 'dir (lambda (name) (map path->string (directory-list name))))

(xdef 'file-exists (lambda (name)
                     (if (file-exists? name) name 'nil)))

(xdef 'dir-exists (lambda (name)
                     (if (directory-exists? name) name 'nil)))

(xdef 'rmfile (wrapnil delete-file))

; top level read-eval-print
; tle kept as a way to get a break loop when a scheme err

(define (arc-eval expr) 
  (eval (ac expr '()) (interaction-environment)))

(define (tle)
  (display "Arc> ")
  (let ((expr (read)))
    (when (not (eqv? expr ':a))
      (write (arc-eval expr))
      (newline)
      (tle))))

(define last-condition* #f)

(define (tl)
  (display "Use (quit) to quit, (tl) to return here after an interrupt.\n")
  (tl2))

(define (tl2)
  (display "arc> ")
  (on-err (lambda (c) 
            (set! last-condition* c)
            (display "Error: ")
            (write (exn-message c))
            (newline)
            (tl2))
    (lambda ()
      (let ((expr (read)))
        (if (eqv? expr ':a)
            'done
            (let ((val (arc-eval expr)))
              (write (ac-denil val))
              (namespace-set-variable-value! '_that val)
              (namespace-set-variable-value! '_thatexpr expr)
              (newline)
              (tl2)))))))

(define (aload1 p)
  (let ((x (read p)))
    (if (eof-object? x)
        #t
        (begin
          (arc-eval x)
          (aload1 p)))))

(define (atests1 p)
  (let ((x (read p)))
    (if (eof-object? x)
        #t
        (begin
          (write x)
          (newline)
          (let ((v (arc-eval x)))
            (if (ar-false? v)
                (begin
                  (display "  FAILED")
                  (newline))))
          (atests1 p)))))

(define (aload filename)
  (call-with-input-file filename aload1))

(define (test filename)
  (call-with-input-file filename atests1))

(define (acompile1 ip op)
  (let ((x (read ip)))
    (if (eof-object? x)
        #t
        (let ((scm (ac x '())))
          (eval scm (interaction-environment))
          (pretty-print scm op)
          (newline op)
          (newline op)
          (acompile1 ip op)))))

; compile xx.arc to xx.arc.scm
; useful to examine the Arc compiler output
(define (acompile inname)
  (let ((outname (string-append inname ".scm")))
    (if (file-exists? outname)
        (delete-file outname))
    (call-with-input-file inname
      (lambda (ip)
        (call-with-output-file outname 
          (lambda (op)
            (acompile1 ip op)))))))

(xdef 'macex (lambda (e) (ac-macex (ac-denil e))))

(xdef 'macex1 (lambda (e) (ac-macex (ac-denil e) 'once)))

(xdef 'eval (lambda (e)
              (eval (ac (ac-denil e) '()) (interaction-environment))))

; If an err occurs in an on-err expr, no val is returned and code
; after it doesn't get executed.  Not quite what I had in mind.

(define (on-err errfn f)
  ((call-with-current-continuation 
     (lambda (k) 
       (lambda () 
         (with-handlers ((exn:fail? (lambda (c) 
                                      (k (lambda () (errfn c)))))) 
                        (f)))))))
(xdef 'on-err on-err)

(define (write-to-string x)
  (let ((o (open-output-string)))
    (write x o)
    (close-output-port o)
    (get-output-string o)))

(xdef 'details (lambda (c)
                 (write-to-string (exn-message c))))

(xdef 'scar (lambda (x val) 
              (if (string? x) 
                  (string-set! x 0 val)
                  (set-car! x val))
              val))

(xdef 'scdr (lambda (x val) 
              (if (string? x)
                  (err "Can't set cdr of a string" x)
                  (set-cdr! x val))
              val))

; When and if cdr of a string returned an actual (eq) tail, could
; say (if (string? x) (string-replace! x val 1) ...) in scdr, but
; for now would be misleading to allow this, because fails for cddr.

(define (string-replace! str val index)
  (if (eqv? (string-length val) (- (string-length str) index))
      (do ((i index (+ i 1)))
          ((= i (string-length str)) str)
        (string-set! str i (string-ref val (- i index))))
      (err "Length mismatch between strings" str val index)))

(xdef 'sref (lambda (com val ind) ; later make ind rest arg
              (cond ((hash-table? com)  (if (eqv? val 'nil)
                                            (hash-table-remove! com ind)
                                            (hash-table-put! com ind val)))
                    ((string? com) (string-set! com ind val))
                    ((pair? com)   (nth-set! com ind val))
                    (#t (err "Can't set reference " com ind val)))
              val))

(define (nth-set! lst n val)
  (set-car! (list-tail lst n) val))

; rewrite to pass a (true) gensym instead of #f in case var bound to #f

(define (bound? arcname)
  (namespace-variable-value (ac-global-name arcname)
                            #t
                            (lambda () #f)))

(xdef 'bound (lambda (x) (if (bound? x) 't 'nil)))

(xdef 'newstring make-string)

(xdef 'truncate (lambda (x) (inexact->exact (truncate x))))

(xdef 'exact (lambda (x) (and (integer? x) (exact? x))))

(xdef 'msec current-milliseconds)
(xdef 'current-process-milliseconds current-process-milliseconds)
(xdef 'current-gc-milliseconds current-gc-milliseconds)

(xdef 'seconds current-seconds)

(print-hash-table #t)

(xdef 'client-ip (lambda (port) 
                   (let-values (((x y) (tcp-addresses port)))
                     y)))

; make sure only one thread at a time executes anything
; inside an atomic-invoke. atomic-invoke is allowed to
; nest within a thread; the thread-cell keeps track of
; whether this thread already holds the lock.
; XXX make sure cell is set #f after an exception?
; maybe it doesn't matter since thread will die?
(define ar-the-sema (make-semaphore 1))
(define ar-sema-cell (make-thread-cell #f))
(xdef 'atomic-invoke (lambda (f)
                       (if (thread-cell-ref ar-sema-cell)
                           (ar-apply f '())
                           (begin
                             (thread-cell-set! ar-sema-cell #t)
                             (let ((ret 
                                    (call-with-semaphore
                                     ar-the-sema
                                     (lambda () (ar-apply f '())))))
                               (thread-cell-set! ar-sema-cell #f)
                               ret)))))

(xdef 'dead thread-dead?) 

; Added because Mzscheme buffers output.  Not sure if want as official
; part of Arc.

;(xdef 'flushout (lambda () (flush-output) 't))

(xdef 'ssyntax (lambda (x) (if (ssyntax? x) 't 'nil)))

(xdef 'ssexpand (lambda (x)
                  (if (symbol? x) (expand-ssyntax x) x)))

(xdef 'seval (lambda (x) (eval (ac-denil x))))

(xdef 'regexp regexp)
(xdef 'r-match regexp-match)
(xdef 'r-match-pos regexp-match-positions)
(xdef 'r-replace regexp-replace)

(xdef 'quit exit)


)

(require ac)

