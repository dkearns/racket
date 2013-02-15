#lang racket/base
(require "read-util.rkt"
         "../dir-chars.rkt"
         racket/set
         racket/port)

#|

todo:
 - backup delta
 - errors
 - do I need absolute positions? (start & end)? yes, for filling gaps.
 - break up the table into two pieces
 ... build test suite


|#

(provide lexer
         cropped-regions)

(define (lexer chained-lexer)
  (define uniform-chained-lexer
    (cond
      [(procedure-arity-includes? chained-lexer 3)
       chained-lexer]
      [else
       (λ (port offset mode)
         (define-values (val tok paren start end) (chained-lexer port))
         (values val tok paren start end 0 #f))]))
  (define (2dcond-lexer port offset _mode)
    (define a-2d-lexer-state (or _mode (2d-lexer-state '() #f #f)))
    (cond
      [(pair? (2d-lexer-state-pending-tokens a-2d-lexer-state))
       (define-values (line col pos) (port-next-location port))
       (define-values (val tok paren start end)
         (apply values (car (2d-lexer-state-pending-tokens a-2d-lexer-state))))
       
       ;; read the characters in (expecting the same string as in 'val')
       (for ([c1 (in-string val)]
             [i (in-naturals)])
         (define c2 (read-char port))
         (unless (or 
                  ;; don't check these, as they are not always
                  ;; right (the ones outside the table, specifically
                  ;; are always just spaces)
                  (eq? tok 'white-space)
                  (equal? c1 c2))
           (error '2d/lexer.rkt "expected a ~s, got ~s while feeding token ~s" c1 c2 
                  (car (2d-lexer-state-pending-tokens a-2d-lexer-state)))))
       
       (values val tok paren 
               pos
               (+ (- end start) pos)
               start
               (struct-copy 2d-lexer-state
                            a-2d-lexer-state
                            [pending-tokens
                             (cdr (2d-lexer-state-pending-tokens 
                                   a-2d-lexer-state))]))]
      [(equal? #\# (peek-char port))
       (define pp (peeking-input-port port))
       (define chars (list (read-char pp) (read-char pp) (read-char pp)))
       (cond
         [(equal? chars '(#\# #\2 #\d))
          (start-new-2d-cond-lexing port a-2d-lexer-state uniform-chained-lexer offset)]
         [else
          (call-chained-lexer uniform-chained-lexer port offset a-2d-lexer-state)])]
      [else
       (call-chained-lexer uniform-chained-lexer port offset a-2d-lexer-state)]))
  2dcond-lexer)


(define double-barred-chars-regexp
  (regexp
   (format "[~a]" (apply string double-barred-chars))))

(define (call-chained-lexer uniform-chained-lexer port offset a-2d-lexer-state)
  (define-values (a b c d e f new-mode) 
    (uniform-chained-lexer port offset (2d-lexer-state-chained-state a-2d-lexer-state)))
  (values a b c d e f (2d-lexer-state '() #f new-mode)))

(struct 2d-lexer-state (pending-tokens read-state chained-state))

(define (start-new-2d-cond-lexing port a-2d-lexer-state uniform-chained-lexer offset)
  (define-values (line col pos) (port-next-location port))
  ;; consume #\# #\2 and #\d that must be there (peeked them earlier)
  (read-char port)
  (read-char port)
  (read-char port)
  ;; read in the keyword and get those tokens
  
  (define-values (backwards-chars eol-string)
    (let loop ([kwd-chars '(#\d #\2 #\#)])
      (define c (peek-char port))
      (cond [(eof-object? c) (values kwd-chars "")]
            [(and (equal? c #\return)
                  (equal? (peek-char port 1) #\newline))
             (values kwd-chars (string c #\newline))]
            [(or (equal? c #\return)
                 (equal? c #\newline))
             (values kwd-chars (string c))]
            [else 
             (read-char port) ;; actually get the char
             (loop (cons c kwd-chars))])))
  (define first-tok-string
    (apply string (reverse backwards-chars)))
  (cond
    [(eof-object? (peek-char port))
     (values first-tok-string 
             'error 
             #f
             pos 
             (+ pos (string-length first-tok-string))
             0
             a-2d-lexer-state)]
    [else
     (define port->peek-port-delta
       (let-values ([(_1 _2 c-pos) (port-next-location port)])
         c-pos))
     (define base-position
       ;; one might think that this should depend on the length of eol-string
       ;; but ports that have port-count-lines! enabled count the \r\n combination
       ;; as a single position in the port, not 2.
       (+ pos port->peek-port-delta -1))
     (define peek-port (peeking-input-port port))
     ;; pull the newline out of the peek-port
     (for ([x (in-range (string-length eol-string))]) (read-char peek-port))
     
     (define the-state (make-state line pos (string-length first-tok-string)))
     (setup-state the-state)
     
     ;; would like to be able to stop this loop
     ;; and process only part of the table,
     ;; but that works only when there are no broken
     ;; edges of the table that span the place I want to stop.
     (define failed
       (with-handlers ((exn:fail:read? 
                        (λ (exn) exn)))
         (let loop ([map #f])
           (define new-map
             ;; this might raise a read exception: what then?
             (parse-2dcond-one-step peek-port (object-name peek-port) #f #f pos the-state map))
           (when new-map
             (loop new-map)))))
     
     (define newline-token
       (list eol-string 'white-space #f 
             (+ pos (string-length first-tok-string))
             ;; no matter how long eol-string is, it counts for 1 position only.
             (+ pos (string-length first-tok-string) 1)))
     
     (define final-tokens
       (cond
         [(exn:fail:read? failed)
          (define error-pos (- (srcloc-position (car (exn:fail:read-srclocs failed)))
                               port->peek-port-delta)) ;; account for the newline
          (define peek-port2 (peeking-input-port port))
          (port-count-lines! peek-port2)
          
          ;; pull the newline out of peek-port2
          (for ([x (in-range (string-length eol-string))]) (read-char peek-port2))
          
          (define (pull-chars n)
            (apply
             string
             (let loop ([n n])
               (cond
                 [(zero? n) '()]
                 [else (cons (read-char peek-port2) (loop (- n 1)))]))))
          (define before-token (list (pull-chars error-pos)
                                     'no-color
                                     #f
                                     (+ base-position 1)
                                     (+ base-position 1 error-pos)))
          (define end-of-table-approx
            (let ([peek-port3 (peeking-input-port peek-port2)])
              (port-count-lines! peek-port3)
              (let loop ()
                (define l (read-line peek-port3))
                (define-values (line col pos) (port-next-location peek-port3))
                (cond
                  [(and (string? l)
                        (regexp-match double-barred-chars-regexp l))
                   (loop)]
                  [else pos]))))
          (define after-token
            (list (pull-chars (- end-of-table-approx 1))
                  'error
                  #f
                  (+ base-position 1 error-pos)
                  (+ base-position 1 error-pos end-of-table-approx -1)))
          (list newline-token before-token after-token)]
         [else
          
          (define lhses (close-cell-graph cell-connections (length table-column-breaks) (length rows)))
          (define scratch-string (make-string (for/sum ([ss (in-list rows)])
                                                (for/sum ([s (in-list ss)])
                                                  (string-length s)))
                                              #\space))
          (define collected-tokens '())
          (define rows-as-vector (apply vector (reverse rows)))
          (for ([set-of-indicies (in-list (sort (set->list lhses) compare/xy 
                                                #:key smallest-representative))])
            (define regions
              (fill-scratch-string set-of-indicies 
                                   rows-as-vector
                                   scratch-string 
                                   table-column-breaks 
                                   initial-space-count
                                   #t))
            (define port (open-input-string scratch-string))
            (let loop ([mode (2d-lexer-state-chained-state a-2d-lexer-state)])
              (define-values (_1 _2 current-pos) (port-next-location port))
              (define-values (str tok paren start end backup new-mode)
                (uniform-chained-lexer port (+ pos offset) mode))
              (unless (equal? 'eof tok)
                (for ([sub-region (in-list (cropped-regions start end regions))])
                  (set! collected-tokens 
                        (cons (list (substring str
                                               (- (car sub-region) current-pos)
                                               (- (cdr sub-region) current-pos))
                                    tok
                                    paren 
                                    (+ base-position (car sub-region)) 
                                    (+ base-position (cdr sub-region)))
                              collected-tokens)))
                (loop new-mode))))
          
          (define (collect-double-barred-token pending-start i offset str)
            (when pending-start
              (set! collected-tokens (cons (list (substring str pending-start i)
                                                 'parenthesis
                                                 #f
                                                 (+ base-position offset pending-start)
                                                 (+ base-position offset i))
                                           collected-tokens))))
          
          (for/fold ([offset 1]) ([strs (in-list (reverse (cons (list current-line) rows)))])
            (for/fold ([offset offset]) ([str (in-list strs)])
              (let loop ([i 0]
                         [pending-start #f])
                (cond
                  [(< i (string-length str))
                   (define c (string-ref str i))
                   (cond
                     [(member c double-barred-chars)
                      (loop (+ i 1)
                            (if pending-start pending-start i))]
                     [else
                      (collect-double-barred-token pending-start i offset str)
                      (loop (+ i 1) #f)])]
                  [else
                   (collect-double-barred-token pending-start i offset str)]))
              (+ (string-length str) offset)))
          
          (define sorted-tokens (sort collected-tokens <
                                      #:key (λ (x) (list-ref x 3))))
          
          ;; there will be gaps that correspond to the places outside of the
          ;; outermost rectangle (at a minimum, newlines); this fills those 
          ;; in with whitespace tokens
          (define cracks-filled-in-tokens
            (let loop ([fst (car sorted-tokens)]
                       [tokens (cdr sorted-tokens)])
              (cond
                [(null? tokens) (list fst)]
                [else
                 (define snd (car tokens))
                 (cond
                   [(= (list-ref fst 4)
                       (list-ref snd 3))
                    (cons fst (loop snd (cdr tokens)))]
                   [else
                    (define new-start (list-ref fst 4))
                    (define new-end (list-ref snd 3))
                    (list* fst
                           (list 
                            ; these are not the real characters ...
                            (make-string (- new-end new-start) #\space)
                            'white-space
                            #f 
                            new-start
                            new-end)
                           (loop snd (cdr tokens)))])])))
          (cons newline-token cracks-filled-in-tokens)]))
     
     (values first-tok-string 'hash-colon-keyword #f
             pos (+ pos (string-length first-tok-string)) 
             0
             (2d-lexer-state final-tokens
                             #t
                             (2d-lexer-state-chained-state a-2d-lexer-state)))]))

(define (cropped-regions start end regions)
  (define result-regions '())
  (define (add start end)
    (unless (= start end)
      (set! result-regions (cons (cons start end) result-regions))))
  (let loop ([regions regions]
             [start start]
             [end end])
    (unless (null? regions)
      (define region (car regions))
      (cond
        [(<= start (car region))
         (cond
           [(<= end (car region))
            (void)]
           [(<= end (cdr region))
            (add (car region) end)]
           [else 
            (add (car region) (cdr region))
            (loop (cdr regions)
                  (cdr region)
                  end)])]
        [(<= start (cdr region))
         (cond
           [(<= end (cdr region))
            (add start end)]
           [else 
            (add start (cdr region))
            (loop (cdr regions)
                  (cdr region) 
                  end)])]
        [else 
         (loop (cdr regions) start end)])))
  result-regions)
  

#|
(define scratch-string (make-string (for/sum ([ss (in-vector lines)])
                                      (for/sum ([s (in-list ss)])
                                        (string-length s)))
                                    #\space))

(define heights
  (for/list ([line (in-vector lines)])
    (length line)))

`(,(string->symbol (string-append "2d" (apply string kwd-chars)))
  
  ,table-column-breaks
  ,heights
  
  ,@(for/list ([set-of-indicies (in-list (sort (set->list lhses) compare/xy 
                                               #:key smallest-representative))])
      (fill-scratch-string set-of-indicies 
                           lines 
                           scratch-string 
                           table-column-breaks 
                           initial-space-count)
      (define scratch-port (open-input-string scratch-string))
      (when post-2d-line (port-count-lines! scratch-port))
      (set-port-next-location! scratch-port post-2d-line post-2d-col post-2d-span)
      `[,(sort (set->list set-of-indicies) compare/xy)
        ,@(read-subparts source scratch-port 
                         initial-space-count table-column-breaks heights set-of-indicies
                         previous-readtable /recursive)]))
|#

#;
(module+ main 
  (define p (open-input-string (string-append
                                "╔══╦══╗\n"
                                "║1 ║2 ║\n"
                                "╠══╬══╣\n"
                                "║4 ║3 ║\n"
                                "╚══╩══╝\n")))
  (port-count-lines! p)
  ;; account for the "#2d" that was read from the first line
  (call-with-values (λ () (tokenize-2dcond p "source" 1 0 1 2))
                    list))