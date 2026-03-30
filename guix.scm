;; SPDX-License-Identifier: PMPL-1.0-or-later
;; Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
;;
;; Guix package definition for game-server-admin
;;
;; Usage:
;;   guix shell -D -f guix.scm    # Enter development shell
;;   guix build -f guix.scm       # Build package
;;
;; Stack: Zig FFI + Idris2 ABI + VeriSimDB
;; See: https://guix.gnu.org/manual/en/html_node/Defining-Packages.html

(use-modules (guix packages)
             (guix gexp)
             (guix git-download)
             (guix build-system gnu)
             (guix licenses)
             (gnu packages base))

(package
  (name "game-server-admin")
  (version "0.1.0")
  (source (local-file "." "source"
                       #:recursive? #t
                       #:select? (lambda (file stat)
                                   (not (string-contains file ".git")))))
  (build-system gnu-build-system)
  (arguments
   '(#:phases
     (modify-phases %standard-phases
       (delete 'configure)
       ;; Build the Zig FFI library and standalone CLI binary.
       (replace 'build
         (lambda _
           (with-directory-excursion "src/interface/ffi"
             (invoke "zig" "build" "-Doptimize=ReleaseSafe"))))
       ;; Run the Zig unit test suite.
       (replace 'check
         (lambda _
           (with-directory-excursion "src/interface/ffi"
             (invoke "zig" "build" "test"))))
       (replace 'install
         (lambda* (#:key outputs #:allow-other-keys)
           (let ((out (assoc-ref outputs "out")))
             (mkdir-p (string-append out "/bin"))
             (mkdir-p (string-append out "/lib"))
             (mkdir-p (string-append out "/share/doc"))
             (mkdir-p (string-append out "/share/game-server-admin/profiles"))
             (copy-file "src/interface/ffi/zig-out/bin/gsa"
                        (string-append out "/bin/gsa"))
             (when (file-exists? "src/interface/ffi/zig-out/lib/libgsa.so")
               (copy-file "src/interface/ffi/zig-out/lib/libgsa.so"
                          (string-append out "/lib/libgsa.so")))
             (copy-file "README.adoc"
                        (string-append out "/share/doc/README.adoc"))
             (for-each
               (lambda (f)
                 (copy-file f
                   (string-append out "/share/game-server-admin/profiles/"
                                  (basename f))))
               (find-files "profiles" "\\.a2ml$"))))))))
  (native-inputs
   (list
    ;; Zig compiler for building the FFI layer
    ;; zig   ; (gnu packages zig) — uncomment when available in Guix
    ))
  (inputs
   (list))
  (home-page "https://github.com/hyperpolymath/game-server-admin")
  (synopsis "Universal game server probe, config management, and administration")
  (description "RSR-compliant project. See README.adoc for details.")
  (license (list
            ;; PMPL-1.0-or-later extends MPL-2.0
            mpl2.0)))
