(= first car)
(= rest cdr)
(= second cadr)
(def third (list) (car (cddr list)))
(def fourth (list) (car (nthcdr 3 list)))
(def fifth (list) (car (nthcdr 4 list)))
(def sixth (list) (car (nthcdr 5 list)))
;; tests have a description, a body, and a procedure
(def def-test (desc body proc) (list desc body proc))
(def test-desc (test) (first test))
(def test-body (test) (second test))
(def test-proc (test) (third test))
(def run-test (test) (test-proc test))
;; specs have a description, setups and teardowns, and a set of tests
(def def-spec (desc all-pro all-epi every-pro every-epi tests)
     (list desc all-pro all-epi every-pro every-epi tests))
(def spec-desc (spec) (first spec))
(def spec-all-prolog (spec) (second spec))
(def spec-all-epi (spec) (third spec))
(def spec-every-pro (spec) (fourth spec))
(def spec-every-epi (spec) (fifth spec))
(def spec-tests (spec) (sixth spec))
;; a result is the description, the body (expected) and a value (nil or non-nil)
(def def-result (desc body value) (list desc body value))
(def result-desc (result) (first result))
(def result-body (result) (second result))
(def result-value (result) (third result))
;; a spec result is the description plus the results
(def def-results (desc results) (list desc results))
(def results-description (results) (first results))
(def results-results (results) (second results))
(def print-results (results (o all nil))
     (pr ";; " (results-description results) "\n")
     (with (totals 0 goods 0 errors 0)
       (each result (results-results results)
         (++ totals)
           (when (result-value result)
             (if (is 'exception (type (result-value result)))
                 (++ errors)
                 (++ goods)))
           (when (or all (no (result-value result)))
             (pr ";; " (result-desc result) ": " (result-value result) "\t"
                 (first (result-body result)) "\n")))
       (pr ";; Tests: " totals "; Good: " goods "; Errors: " errors "; Pct: " (* 100.0 (/ goods totals)) "\n")
       (if (is totals goods)
           'green
           'red)))
                      
                
;; running a spec. note assumes prologs and epilogs are defined.
;; returns a result
(def eval-spec (spec)
     (def-results
       (spec-desc spec)
       (do ((spec-all-prolog spec))
           (do1
            (map (fn (test)
                     ((spec-every-pro spec))
                     (do1
                      (def-result
                        (test-desc test)
                        (test-body test)
                        (on-err (fn (err) err) (test-proc test)))
                      ((spec-every-epi spec))))
                 (spec-tests spec))
            ((spec-all-epi spec))))))

            
(def assocs (key list)
     (keep [and (acons _) (is (car _) key)] list))

(mac describe body
     (with (desc (car body)
            prolog (cdr (assoc 'prolog (cdr body)))
            epilog (cdr (assoc 'epilog (cdr body)))
            setup  (cdr (assoc 'setup (cdr body)))
            teardown (cdr (assoc 'teardown (cdr body)))
            its (assocs 'it (cdr body)))
           `(def-spec ,desc
              (fn () ,@prolog)
              (fn () ,@epilog)
              (fn () ,@setup)
              (fn () ,@teardown)
              (list ,@(map (fn (it)
                             (with (desc (second it)
                                    body (cddr it))
                             `(def-test
                                ,desc
                                ',body
                                (fn () ,@body))))
                           its)))))
                            
;; -- example spec

(print-results
 (eval-spec
    (describe "Testing basic Arc list operations"
              (prolog (pr "\n;; This is the prolog\n"))
              (epilog (pr ";; This is the epilog\n"))
              (setup (pr ";; Setting up\n"))
              (teardown (pr ";; Tearing down\n"))
              (it "should support CAR"
                  (is (car '(a b c)) 'a))
              (it "should support CDR"
                  (iso (cdr '(a b c)) '(b c)))
              (it "should get this test wrong"
                  (acons (car nil)))
              (it "should catch errors"
                  (is 0 (/ 1 0))))))