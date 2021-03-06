#lang racket

(define here (current-directory))
(define txt (build-path here "some.txt"))

(with-output-to-file txt
  #:exists 'replace
  (lambda ()
    (display #<<END
Here is some text that looks at @this
END
  )))

(with-output-to-file "relative.rkt"
  #:exists 'replace
  (lambda ()
    (display #<<END
#lang racket
(require web-server/templates)
(provide ans)

(define this 5)
(define ans (include-template "some.txt"))
END
  )))

(with-output-to-file "absolute.rkt"
  #:exists 'replace
  (lambda ()
    (display #<<END
#lang racket
(require web-server/templates)
(provide ans)

(define this 5)
(define ans (include-template (file "
END
  )

 (display (path->string txt))

(display #<<END
")))
END
)))

(require tests/eli-tester)
(define rel (dynamic-require "relative.rkt" 'ans))
(define abs (dynamic-require "absolute.rkt" 'ans))
(test
  rel => abs
  rel => "Here is some text that looks at 5")



