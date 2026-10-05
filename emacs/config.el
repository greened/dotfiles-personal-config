;; -*- lexical-binding: t -*-
;;
;; Personal (non-sensitive) overlay.  Loaded after the public base config.
;; Holds personal-but-shareable configuration: my own C style, the MIRV
;; project build hydra, and the LLVM / C++ standards mailing-list saved
;; searches.  Nothing here is sensitive or identity-bearing; that lives in
;; the private (secret) overlay.

;;; org-jira: install the package generically.  Employer-specific
;;; configuration (Jira URL, JQL, store-link advice) lives in a private
;;; overlay via `with-eval-after-load'.

(use-package org-jira
  :ensure t
  :requires (org)
  :config
  (require 'org-jira))

;;; cc-mode: my personal C style and its guesser entries.

(with-eval-after-load 'cc-styles
  (defconst my-c-style
    '((c-tab-always-indent        . t)
      (c-comment-only-line-offset . 4)
      (c-basic-offset . 2)
      (c-hanging-braces-alist . ((brace-list-open after)
				 (brace-entry-open after)
				 (class-open after)
				 (inline-open after)
				 (statement-cont)
				 (substatement-open after)
				 (block-open after)
				 (block-close . c-snug-do-while)
				 (statement-case-open after)
				 (substatement-open after)
				 (namespace-open after)
				 (extern-lang-open after)
				 (inexpr-class-open after)
				 (inexpr-class-close before)))
      (c-hanging-colons-alist . ((case-label after)
				 (access-label after)
				 (label after)
				 (member-init-intro before)
				 (inher-intro before)))
      (c-cleanup-list . (empty-defun-braces
			 defun-close-semi
			 list-close-comma
			 compact-empty-funcall
			 scope-operator))
      (c-offsets-alist . ((string . -1000)
			  (c . c-lineup-C-comments)
			  (defun-open . 0)
			  (defun-close . 0)
			  (defun-block-intro . +)
			  (class-open . 0)
			  (class-close . 0)
			  (inline-open . 0)
			  (inline-close . 0)
			  (func-decl-cont . +)
			  (knr-argdecl-intro . +)
			  (knr-argdecl . 0)
			  (topmost-intro . 0)
			  (topmost-intro-cont . 0)
			  (member-init-intro . ++)
			  (member-init-cont . +)
			  (inher-intro . ++)
			  (inher-cont . +)
			  (block-open . 0)
			  (block-close . 0)
			  (brace-list-open . 0)
			  (brace-list-close . 0)
			  (brace-list-intro . +)
			  (brace-list-entry . 0)
			  (brace-entry-open . +)
			  (statement . 0)
			  (statement-cont . +)
			  (statement-block-intro . +)
			  (statement-case-intro . +)
			  (statement-case-open . 0)
			  (substatement . +)
			  (substatement-open . 0)
			  (case-label . 0)
			  (access-label . -)
			  (label . -1000)
			  (do-while-closure . 0)
			  (else-clause . 0)
			  (catch-clause . 0)
			  (comment-intro . 0)
			  (arglist-intro . +)
			  (arglist-cont . 0)
			  (arglist-cont-nonempty . c-lineup-arglist)
			  (arglist-close . c-lineup-close-paren)
			  (stream-op . +)
			  (inclass . +)
			  (cpp-macro . -1000)
			  (cpp-macro-cont . 0)
			  (friend . 0)
			  (objc-method-intro . +)
			  (objc-method-args-cont . 0)
			  (objc-method-call-cont . +)
			  (extern-lang-open . 0)
			  (extern-lang-close . 0)
			  (inextern-lang . +)
			  (namespace-open . 0)
			  (namespace-close . 0)
			  (innamespace . +)
			  (module-open . 0)
			  (module-close . 0)
			  (inmodule . +)
			  (composition-open . 0)
			  (composition-close . 0)
			  (incomposition . +)
			  (template-args-cont . +)
			  (inlambda . +)
			  (lambda-intro-cont . +)
			  (inexpr-statement . +)
			  (inexpr-class . +))))
    "My personal C Style")
  (c-add-style "my-c-style" my-c-style)

  ;; MIRV (personal project) C style, inheriting my-c-style.
  (defconst mirv-c-style
    '("my-c-style")
    "MIRV C Style")
  (c-add-style "mirv-c-style" mirv-c-style))

(with-eval-after-load 'cc-mode
  (add-to-list 'my-c-styles-alist
	       '(".*/.*mirv/.*\\.[ch]$" . "mirv-c-style")))

;;; quite: MIRV build hydra.


(with-eval-after-load 'quite
  (setq git-mirv-name "mirv")

  ;; Prefixes: list order is the C-u dispatch index (release = no prefix,
  ;; debug = one C-u).
  (setq mirv-prefix-plist-list '("release" "debug"))

  (setq mirv-transform-plist-list '((:name "clang" :func identity)
				    (:name "gcc" :func upcase)))

  (setq mirv-project-dir "mirv-project")
  (setq mirv-root-list '("/home/dag/src"))

  (setq mirv-project-descriptor
	`(:project-dir ,mirv-project-dir
		       :root-list ,mirv-root-list
		       :key-files ("repositories.manifest")))

  (setq mirv-hydra-heads
        (quite-define-project
         (list :git-name git-mirv-name :name "mirv"
               :descriptor mirv-project-descriptor :prefix-key "M" :target "all"
               :commands command-plist-list :prefixes mirv-prefix-plist-list
               :transforms mirv-transform-plist-list
               :command-prefix "/bin/bash -c '. /usr/share/virtualenvwrapper/virtualenvwrapper.sh; workon mirv;"
               :command-postfix "-- --force'")))

  (setq mirv-build-hydra-heads (append mirv-hydra-heads))

  ;; Create build hydra.
  (eval `(defhydra mirv-hydra-build (:color blue :hint nil)
	   ,@(append
	      mirv-build-hydra-heads)))

  (define-key quite-command-map (kbd "Mh")
		   (lambda () (interactive) (mirv-hydra-build/body))))

(with-eval-after-load 'quite
  ;; Every one of these is a shell project: quite runs the command's
  ;; :shell-command and nothing else.  They have a single build flavor, so none
  ;; declares :prefixes or :transforms -- the lone flavor is named by :target
  ;; and there are no C-u variants.  Two commands each, deliberately: `build'
  ;; and `check' are the verbs gaffer drives (`quite-run-repo' looks them up by
  ;; :command), and for a repo whose whole check is one script they are the same
  ;; script.
  (dolist (p '(("gaffer"          "f" ("gaffer.el" "check.sh"))
               ("prevue"          "v" ("prevue.el" "check.sh"))
               ("gazette"         "z" ("gazette.el" "check.sh"))
               ("quarry"          "q" ("quarry.el" "check.sh"))
               ("slack-attention" "a" ("check.sh"))))
    (let ((name (nth 0 p)) (key (nth 1 p)) (files (nth 2 p)))
      (quite-define-project
       (list :name name
             :build-architecture 'shell
             :descriptor (list :project-dir name
                               :root-list '("/Users/dag/projects")
                               :key-files files)
             :prefix-key key
             :target name
             :commands '((:name "build" :command "build" :key "b"
                                :shell-command "./check.sh")
                         (:name "check" :command "check" :key "k"
                                :shell-command "./check.sh"))))
      (quite-register-repo (concat "greened/" name)
                           :project name
                           :build-target name
                           :test-target name)))

  ;; quite builds with Cask and a Makefile rather than a ./check.sh, and cask
  ;; lives under ~/.cask on the build host, so it needs its own commands.
  ;; `make deps' populates the Cask sandbox in a fresh worktree first.
  (quite-define-project
   (list :name "quite"
         :build-architecture 'shell
         :descriptor '(:project-dir "quite"
                       :root-list ("/Users/dag/projects")
                       :key-files ("quite.el" "Cask"))
         :prefix-key "t"
         :target "quite"
         :commands '((:name "build" :command "build" :key "b"
                            :shell-command "PATH=$HOME/.cask/bin:$PATH make deps compile")
                     (:name "check" :command "check" :key "k"
                            :shell-command "PATH=$HOME/.cask/bin:$PATH make test"))))
  (quite-register-repo "greened/quite"
                       :project "quite" :build-target "quite" :test-target "quite")

  ;; The Python packages build with uv, which both machines have.  Building the
  ;; distribution is deliberately NOT the build verb: it writes dist/ into the
  ;; worktree, and those artifacts are untracked, so they would surface as
  ;; noise in every later worktree review.  Creating the environment is
  ;; idempotent, leaves nothing a review sees (uv writes a .venv/.gitignore
  ;; holding "*"), and still fails when the environment cannot be built --
  ;; which is what a build gate is for.
  ;;
  ;; The two packages are developed together, and core-plugins pins a
  ;; git-project that is not released yet, so each environment installs the
  ;; sibling from a local checkout instead of from the index.  Otherwise which
  ;; sibling gets tested depends on what the index happens to hold.  $s finds
  ;; that checkout under either layout: a worktree sits beside the repo on the
  ;; build VM and one directory deeper on the laptop, so probe the flat layout
  ;; first and fall back to the nested one.
  ;;
  ;; Which of the two carries the dependencies is fixed by ROLE, not by which
  ;; one is under test.  git-project always installs WITH its dependencies and
  ;; core-plugins always installs --no-deps, whichever of them is the project
  ;; and whichever is the sibling.  Only core-plugins names a floor the index
  ;; cannot satisfy -- it needs the git-project API that is still unreleased --
  ;; so resolving its dependencies asks for a version that cannot exist, while
  ;; git-project's own are ordinary third-party packages.  A symmetric rule
  ;; reads better and fails: building git-project then installs core-plugins
  ;; with dependencies, and uv refuses the whole environment.  That made
  ;; git-project's build gate depend on a release of git-project.
  ;;
  ;; The check ignores the user's git configuration.  One core-plugins test
  ;; pushes to a fixture remote and would otherwise fire the pre-push hook.
  (dolist (p '(("git-project" "j" "git-project-core-plugins")
               ("git-project-core-plugins" "P" "git-project")))
    (let* ((name (nth 0 p)) (key (nth 1 p)) (sibling (nth 2 p))
           (self-is-git-project (equal name "git-project"))
           ;; The path of each role, as the shell sees it: one is ".", the
           ;; other is the "$s" the probe below resolves.
           (git-project-path (if self-is-git-project "." "\"$s\""))
           (core-plugins-path (if self-is-git-project "\"$s\"" "."))
           (find-sibling
            (format "s=../%s; [ -f \"$s/pyproject.toml\" ] || s=../../%s/master;"
                    sibling sibling)))
      (quite-define-project
       (list :name name
             :build-architecture 'shell
             :descriptor (list :project-dir name
                               :root-list '("/Users/dag/projects")
                               :key-files '("pyproject.toml"))
             :prefix-key key
             :target name
             :commands
             (list (list :name "build" :command "build" :key "b"
                         :shell-command
                         (concat find-sibling
                                 " uv venv --python 3.11 --allow-existing .venv"
                                 " && uv pip install --python .venv/bin/python"
                                 " -q -e " git-project-path
                                 " pytest pytest-console-scripts"
                                 " && uv pip install --python .venv/bin/python"
                                 " -q --no-deps -e " core-plugins-path))
                   (list :name "check" :command "check" :key "k"
                         :shell-command
                         (concat "GIT_CONFIG_GLOBAL=/dev/null"
                                 " GIT_CONFIG_NOSYSTEM=1"
                                 " .venv/bin/python -m pytest tests -q")))))
      (quite-register-repo (concat "greened/" name)
                           :project name
                           :build-target name
                           :test-target name))))

;;; gaffer: how my personal repos publish.  Every one of them is a quite
;;; project (the block above), so none needs a `gaffer-repo-build-backends'
;;; override any more -- gaffer's global `quite' backend, which the work overlay
;;; pins, now reaches them through quite itself.  One mechanism per repo.
;;;
;;; What they DO need is a publish strategy.  Without one the default resolution
;;; reaches its last clause -- no PR number, not listed here, branch is not the
;;; default branch -- and picks `open-pr', which would open a pull request on
;;; repos that have never had one.  They all land the same way: fast-forward the
;;; default branch.

;;; The dotfiles repos land the same way, and are listed here for the same
;;; reason: without an entry the default resolution sees a dev branch that is
;;; not the default branch and picks `open-pr', which would open a pull request
;;; on repos that have never had one.  The work overlay adds its own, since
;;; naming it here would put the employer in a public repo.
(with-eval-after-load 'gaffer
  (dolist (repo '("greened/gaffer" "greened/prevue" "greened/gazette"
                  "greened/quarry" "greened/slack-attention" "greened/quite"
                  "greened/git-project" "greened/git-project-core-plugins"
                  "greened/dotfiles-public" "greened/dotfiles-personal-config"
                  "greened/dotfiles-personal-secret"))
    (setf (alist-get repo gaffer-repo-publish-strategies nil nil #'equal)
          'ff-merge)))

;;; gaffer: where git-project and core-plugins live on disk.  Without an entry
;;; `gaffer--repo-path' raises, and that costs two separate things.  Worktree
;;; resolution goes away, so an item's `worktree' has to be set by hand.  And
;;; `gaffer--released-p' loses the fallback it reads once a worktree is torn
;;; down, which is normal after landing.
;;;
;;; The second one is the dangerous half.  That call sits inside
;;; `ignore-errors', so the raise is swallowed and the answer is nil -- and nil
;;; does not merely park the item, it also stops `gaffer-release' recognising a
;;; cut somebody already made.  A missing path turns a no-op into a DUPLICATE
;;; release.
;;;
;;; The path is the WORKTREE, not the directory above it.  Both repos use the
;;; nested layout, so the parent holds the bare store and no working tree at
;;; all; git run there reports "not a git repository".  A worktree shares the
;;; object store, so tags resolve identically either way.
;;;
;;; These are laptop paths, unlike the work repos above, which are TRAMP
;;; handles to the VM.  `dag/gaffer-release-pypi' already hardcodes this same
;;; ~/projects/<name>/master, and a release is laptop-only, so a local checkout
;;; also spares every queue refresh a TRAMP hop.
(with-eval-after-load 'gaffer
  (dolist (name '("git-project" "git-project-core-plugins"))
    (setf (alist-get (concat "greened/" name) gaffer-repo-paths nil nil #'equal)
          (expand-file-name (format "~/projects/%s/master" name)))))

;;; gaffer: how git-project and core-plugins RELEASE.  Landing is not shipping
;;; for these two.  They are python packages on PyPI, so `done' has to mean
;;; RELEASED rather than merged, and listing them in
;;; `gaffer-repo-release-strategies' is what says so.  Every other repo above
;;; has no entry, rolls through `to-release' untouched, and keeps `done' meaning
;;; MERGED.
;;;
;;; The handler tags, builds and uploads as ONE act, which is deliberate rather
;;; than a shortcut.  `gaffer--released-p' answers "has this shipped?" by
;;; running `git tag --contains', and that is what lets one release clear every
;;; other item parked at `to-release'.  A tag standing on its own would
;;; therefore make gaffer believe work shipped when it had not.  Hence two
;;; safeguards: the local tag is deleted if any later step fails, and the tag is
;;; pushed LAST, only after a successful upload.
;;;
;;; It runs on this machine.  The token lives in `pass', which is not installed
;;; on the build VM and is not going to be, so a release is laptop-only however
;;; the artifact gets built.

(defun dag/release--git (&rest args)
  "Run git with ARGS in `default-directory'.
Return a cons of the exit status and the trimmed output."
  (with-temp-buffer
    (cons (apply #'call-process "git" nil t nil args)
          (string-trim (buffer-string)))))

(defun dag/release--git! (&rest args)
  "Run git with ARGS, signalling on a non-zero exit.  Return trimmed output."
  (let ((result (apply #'dag/release--git args)))
    (unless (zerop (car result))
      (error "git %s: %s" (string-join args " ") (cdr result)))
    (cdr result)))

(defun dag/release--bump (tag)
  "Increment TAG's final numeric component, so \"v0.0.37\" gives \"v0.0.38\".
Return TAG unchanged when it does not end in a number."
  (if (string-match "\\`\\(.*[^0-9]\\)\\([0-9]+\\)\\'" tag)
      (concat (match-string 1 tag)
              (number-to-string (1+ (string-to-number (match-string 2 tag)))))
    tag))

(defun dag/release--run (buffer program &rest args)
  "Run PROGRAM with ARGS, logging into BUFFER, and return its exit status.
Wait with `accept-process-output' rather than using `call-process', so that
redisplay, C-g and gpg-agent's pinentry keep working while a build or an upload
runs.  A synchronous call freezes Emacs for the whole release, and against a
cold gpg-agent it can wedge it outright.

Two details are load-bearing.  Give the child a PIPE rather than a pty, so gpg
cannot decide to prompt on a terminal nothing is reading.  And drain after the
process dies, because `process-live-p' goes nil as soon as the exit is
recorded, which says nothing about whether the output has been read out of the
pipe yet.  `call-process' guaranteed that; a liveness loop alone does not."
  (let* ((process-connection-type nil)
         (proc (apply #'start-file-process
                      (format "dag-release-%s" program) buffer program args)))
    ;; Never prompt about killing it: this runs inside an `unwind-protect', and
    ;; a query there can strand the buffer it is trying to clean up.
    (set-process-query-on-exit-flag proc nil)
    (unwind-protect
        (progn
          (while (process-live-p proc)
            (accept-process-output proc 0.2))
          (while (accept-process-output proc 0.2))
          (process-exit-status proc))
      (when (process-live-p proc)
        (kill-process proc)))))

(defun dag/release--pass (entry)
  "Return the first line of pass ENTRY, leaving it in no live buffer.
Read through `dag/release--run', so a pinentry prompt cannot freeze Emacs, and
kill the buffer afterwards rather than let a token sit in one.  The kill is
unconditional: `kill-buffer-query-functions' is bound away so a surviving
process cannot turn the cleanup into a question and strand the token."
  (let ((buffer (generate-new-buffer " *dag-release-pass*")))
    (unwind-protect
        (progn
          (unless (zerop (dag/release--run buffer "pass" "show" entry))
            (error "gaffer release: pass show %s failed" entry))
          (with-current-buffer buffer
            (goto-char (point-min))
            (buffer-substring-no-properties (point) (line-end-position))))
      (let ((kill-buffer-query-functions nil))
        (kill-buffer buffer)))))

(defun dag/release--step (name what &optional no-interrupt)
  "Say in the echo area that NAME's release starts step WHAT.
With NO-INTERRUPT, also say not to interrupt it."
  (message (if no-interrupt
               "gaffer: %s release: %s... (do not interrupt)"
             "gaffer: %s release: %s...")
           name what))

(defun dag/release--existing-tag (tag landed)
  "Decide what to do with TAG when it already exists, before LANDED ships.
Return nil when there is no such tag, so the caller makes one. Return `reuse'
when TAG already sits at LANDED and the user agrees to release anyway.
Return the old tag object when the user agrees to move TAG to LANDED, so a
failed release can put it back. Signal an error to refuse.

A pushed tag that sits elsewhere is refused. Moving it would rewrite what
other clones fetched, so that move is left to a person."
  (unless (string-empty-p (dag/release--git! "tag" "--list" tag))
    (let* ((ref (concat "refs/tags/" tag))
           (at (dag/release--git! "rev-parse" (concat ref "^{commit}")))
           (pushed (not (string-empty-p
                         (dag/release--git! "ls-remote" "--tags" "origin"
                                            ref)))))
      (cond
       ;; An earlier run that uploaded and then failed to push leaves exactly
       ;; this tag, and PyPI refuses that version a second time. So ask.
       ((equal at landed)
        (unless (y-or-n-p
                 (format (if pushed
                             "Tag %s is already pushed, so PyPI may have \
this version. Release anyway? "
                           "Tag %s already sits here, so an earlier run may \
have uploaded it. Release anyway? ")
                         tag))
          (error "gaffer release: tag %s already exists" tag))
        'reuse)
       (pushed
        (error "gaffer release: tag %s is pushed at %s, not at %s"
               tag (substring at 0 8) (substring landed 0 8)))
       ((y-or-n-p (format "Tag %s is at %s. Move it to %s? "
                          tag (substring at 0 8) (substring landed 0 8)))
        (dag/release--git! "rev-parse" ref))
       (t
        (error "gaffer release: tag %s already exists" tag))))))

(defun dag/gaffer-release-pypi (item strategy)
  "Cut ITEM's PyPI release and return the tag, for `gaffer-release-function'.

Tag ITEM's own commit, which is the release CUT POINT.  Everything up to and
including it ships and its items clear to `done'.  Anything that landed after
it stays parked at `to-release' for a later cut.  That falls out of
`gaffer--released-p' testing CONTAINMENT, so cutting at an item is how you
choose where a release stops.

Build in a throwaway worktree at the tag rather than in the clone.  hatch-vcs
takes the version from the tag reachable at zero distance from the BUILD TREE,
so building the clone's HEAD would both version the artifact .devN past the tag
and ship the commits that were deliberately left parked.

Read the token after the cheap checks and before anything irreversible.  Run
that read, the build and the upload through `dag/release--run', so a pinentry
prompt or a slow upload leaves Emacs usable.  The git plumbing stays
synchronous, since it costs milliseconds.

Refuse rather than reset when the clone is not current.  A release is the wrong
place to discard local state."
  (unless (eq strategy 'pypi)
    (error "gaffer release: %s has strategy %S, not pypi"
           (gaffer-item-repo item) strategy))
  (let* ((name (file-name-nondirectory (gaffer-item-repo item)))
         (default-directory
          (expand-file-name (format "~/projects/%s/master/" name)))
         (landed (or (gaffer--release-sha item)
                     (error "gaffer release: %s has no landed commit" name)))
         (tagged nil)
         (moved nil)
         (existing nil)
         (build-dir nil))
    (unless (file-directory-p default-directory)
      (error "gaffer release: no clone at %s" default-directory))
    (dag/release--step name "clean check")
    (unless (string-empty-p (dag/release--git! "status" "--porcelain" "-uno"))
      (error "gaffer release: %s has tracked changes" name))
    (dag/release--step name "fetch tags")
    (dag/release--git! "fetch" "--tags" "--quiet" "origin")
    (dag/release--step name "ancestry check")
    (let ((head (dag/release--git! "rev-parse" "HEAD"))
          (remote (dag/release--git! "rev-parse" "origin/master")))
      (unless (equal head remote)
        (error "gaffer release: %s is not at origin/master, sync it first" name))
      (unless (zerop (car (dag/release--git "merge-base" "--is-ancestor"
                                            landed "HEAD")))
        (error "gaffer release: %s is not an ancestor of the head"
               (substring landed 0 8)))
      (let* ((last (dag/release--git! "describe" "--tags" "--abbrev=0"))
             (since (dag/release--git! "rev-list" "--count"
                                       (concat last ".." landed)))
             (after (dag/release--git! "rev-list" "--count"
                                       (concat landed "..HEAD")))
             (tag (read-string
                   (format "%s: tag %s (%s since %s, %s stay parked) as: "
                           name (substring landed 0 8) since last after)
                   (dag/release--bump last))))
        (when (string-empty-p tag)
          (error "gaffer release: no tag given"))
        (setq existing (dag/release--existing-tag tag landed))
        ;; Only now read the token: a typo at the prompt or a tag that cannot
        ;; be used costs no pinentry round-trip, and a missing entry still
        ;; fails before the tag is created.
        (let ((token (dag/release--pass
                      "upload.pypi.org/legacy/__token__/password")))
          (when (string-empty-p token)
            (error "gaffer release: pass entry is empty"))
          (unwind-protect
              (progn
                ;; Tag first: the build reads the version off this tag.
                (cond
                 ((eq existing 'reuse))
                 (existing
                  (dag/release--step name (concat "move tag " tag))
                  (dag/release--git! "tag" "--force" tag landed)
                  (setq moved existing))
                 (t
                  (dag/release--step name (concat "tag " tag))
                  (dag/release--git! "tag" tag landed)
                  (setq tagged tag)))
                (setq build-dir (make-temp-file "gaffer-release-" t))
                (dag/release--git! "worktree" "add" "--detach" build-dir tag)
                (let ((default-directory (file-name-as-directory build-dir)))
                  (dag/release--step name "build")
                  (unless (zerop (dag/release--run "*gaffer-release*" "uv"
                                                   "build"))
                    (error
                     "gaffer release: uv build failed, see *gaffer-release*"))
                  ;; Only ever through the environment.  A --token argument
                  ;; would be readable from the process table.
                  (let ((process-environment
                         (cons (concat "UV_PUBLISH_TOKEN=" token)
                               process-environment)))
                    ;; PyPI does not accept the same version twice. An
                    ;; interrupt after this point leaves an upload with no tag.
                    (dag/release--step name "upload" t)
                    (unless (zerop (dag/release--run "*gaffer-release*" "uv"
                                                     "publish"))
                      (error "gaffer release: uv publish failed, see %s"
                             "*gaffer-release*"))))
                ;; Uploaded.  Push the tag only now, so the remote never carries
                ;; a tag for a release that did not happen.  Clear the rollback
                ;; BEFORE pushing: the version is irreversible from here, so a
                ;; failed push has to leave the tag in place to be pushed again,
                ;; not delete a tag whose version is already published.
                (setq tagged nil moved nil)
                (dag/release--step name "push tag" t)
                (dag/release--git! "push" "origin" tag)
                tag)
            (when build-dir
              (ignore-errors
                (dag/release--git "worktree" "remove" "--force" build-dir)))
            (when tagged
              (dag/release--git "tag" "-d" tagged))
            ;; A moved tag goes back to its old object, so an annotated tag
            ;; keeps its annotation.
            (when moved
              (dag/release--git "update-ref" (concat "refs/tags/" tag)
                                moved))))))))

(with-eval-after-load 'gaffer
  (setq gaffer-release-function #'dag/gaffer-release-pypi)
  (dolist (repo '("greened/git-project" "greened/git-project-core-plugins"))
    (setf (alist-get repo gaffer-repo-release-strategies nil nil #'equal)
          'pypi)))

;;; Build and test the dotfiles repos with their own scripts rather than the
;;; fleet-wide backend, which is a build tool that has never heard of them.
;;;
;;; Wired because a repo with no build backend can NEVER satisfy the `built'
;;; gate: gaffer requires the `:build-ok' artifact to be PRESENT, an absent one
;;; reads as unverified, and leaving the stage then takes a human override every
;;; single time.  A routine override is how a gate stops meaning anything, and
;;; there is real work to check here -- byte-compiling the local packages caught
;;; a live error the tests missed.
;;;
;;; The two overlays that genuinely have nothing to build are still stuck, since
;;; there is no way to declare that; see the per-repo-stage-configuration todo.
(with-eval-after-load 'gaffer
  (setf (alist-get "greened/dotfiles-public" gaffer-repo-build-backends
                   nil nil #'equal)
        '(:build-backend shell :build-command "./check.sh build"
          :test-backend  shell :test-command  "./check.sh test"))
  ;; This repo has no elisp of its own to compile -- its content is the git hook
  ;; chain -- so only the test half is real work.  The selftest covers the
  ;; scrub's shape rules and its literal-term builder.
  ;;
  ;; The build command is a deliberate stand-in, and states as much when it
  ;; runs.  An ABSENT `:build-backend' would fall back to the fleet-wide one,
  ;; which is a build tool that knows nothing about this repo, so the choice is
  ;; not between this and nothing -- it is between saying "nothing to build" out
  ;; loud and running something meaningless.  Replace it with a declared
  ;; no-build once gaffer can express one.
  (setf (alist-get "greened/dotfiles-personal-config" gaffer-repo-build-backends
                   nil nil #'equal)
        '(:build-backend shell
          :build-command "echo 'nothing to build: hook scripts and config only'"
          :test-backend  shell
          :test-command  "git/hooks/scrub-selftest.sh")))

;;; Calendars for the agenda.  The package is declared in the public base; what
;;; belongs here is which calendars to read.
;;;
;;; The address is a `pass' entry read through a lambda rather than a string,
;;; per the token-provider pattern the other packages use: a Google secret
;;; calendar address is a credential -- it grants read access to the whole
;;; calendar to anyone holding it -- so it must not sit in a repo, public or
;;; not.  The lambda defers the lookup to fetch time, so a rotated address is
;;; picked up without restarting Emacs.
;;;
;;; The work calendar is not here.  It goes in the work overlay once it has a
;;; published iCalendar address, and joins this same alist.

(with-eval-after-load 'agenda-feeds
  (setq agenda-feeds-calendars
        (list (cons 'personal
                    (lambda ()
                      (auth-source-pass-get
                       'secret
                       "calendar.google.com/greened.obbligato.org/ics-url"))))))

;;; Notmuch: LLVM project and C++ standards mailing-list saved searches.

(with-eval-after-load 'notmuch
  (my-notmuch-add-search "llvm-feedback" "f" "tag:llvm-feedback and not tag:deleted and not tag:trash" 'tree)
  (my-notmuch-add-search "llvm-iropt" "I" "tag:llvm-ir-opt and not tag:deleted and not tag:trash" 'tree)
  (my-notmuch-add-search "llvm-infrastructure" "F" "tag:llvm-infrastructure and not tag:deleted and not tag:trash" 'tree)
  (my-notmuch-add-search "llvm-beginners" "b" "tag:llvm-beginners and not tag:deleted and not tag:trash" 'tree)
  (my-notmuch-add-search "llvm-jobs" "j" "tag:llvm-jobs and not tag:deleted and not tag:trash" 'tree)
  (my-notmuch-add-search "llvm-announce" "a" "tag:llvm-announce and not tag:deleted and not tag:trash" 'tree)
  (my-notmuch-add-search "llvm-codegen" "g" "tag:llvm-codegen and not tag:deleted and not tag:trash" 'tree)
  (my-notmuch-add-search "llvm-community" "g" "tag:llvm-community and not tag:deleted and not tag:trash" 'tree)
  (my-notmuch-add-search "llvm-project" "g" "tag:llvm-project and not tag:deleted and not tag:trash" 'tree)
  (my-notmuch-add-search "llvm-github" "g" "tag:llvm-github and not tag:deleted and not tag:trash" 'tree)
  (my-notmuch-add-search "llvm-dev" "l" "tag:llvm-dev and not tag:deleted and not tag:trash" 'tree)
  (my-notmuch-add-search "llvm-commits" "L" "tag:llvm-commits and not tag:deleted and not tag:trash" 'unthreaded)
  (my-notmuch-add-search "cfe-dev" "c" "tag:cfe-dev and not tag:deleted and not tag:trash" 'tree)
  (my-notmuch-add-search "cfe-commits" "C" "tag:cfe-commits and not tag:deleted and not tag:trash" 'unthreaded)
  (my-notmuch-add-search "flang-dev" "F" "tag:flang-dev and not tag:deleted and not tag:trash" 'tree)
  (my-notmuch-add-search "libcxx-dev" "x" "tag:libcxx-dev and not tag:deleted and not tag:trash" 'tree)
  (my-notmuch-add-search "lldb-dev" "B" "tag:lldb-dev and not tag:deleted and not tag:trash" 'tree)
  (my-notmuch-add-search "openmp-dev" "o" "tag:openmp-dev and not tag:deleted and not tag:trash" 'tree)
  (my-notmuch-add-search "mlir-dev" "c" "tag:mlir-dev and not tag:deleted and not tag:trash" 'tree)
  (my-notmuch-add-search "std-proposals" "P" "tag:std-proposals and tag:unread and not tag:deleted and not tag:trash" 'tree)
  (my-notmuch-add-search "std-discussion" "d" "tag:std-discussion and tag:unread and not tag:deleted and not tag:trash" 'tree))
