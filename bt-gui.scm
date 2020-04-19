;; This file is part of Bintracker.
;; Copyright (c) utz/irrlicht project 2019-2020
;; See LICENSE for license details.

;; -----------------------------------------------------------------------------
;;; # Bintracker GUI abstractions
;; -----------------------------------------------------------------------------


(module bt-gui
    *

  (import scheme (chicken base) (chicken pathname) (chicken string)
	  (chicken sort) list-utils srfi-1 srfi-13 srfi-69
	  coops typed-records simple-exceptions pstk stack comparse
	  bt-state bt-types bt-db mdal)

  ;; ---------------------------------------------------------------------------
  ;;; ## Utilities
  ;; ---------------------------------------------------------------------------

  ;;; update window title by looking at current file name and 'modified'
  ;;; property
  (define (update-window-title!)
    (tk/wm 'title tk (if (state 'current-file)
			 (string-append (pathname-file (state 'current-file))
					(if (state 'modified)
					    "*" "")
					" - Bintracker")
			 (if (current-mod)
			     "unknown* - Bintracker"
			     "Bintracker"))))

  ;;; Thread-safe version of tk/bind. Wraps the procedure PROC in a thunk
  ;;; that is safe to execute as a callback from Tk.
  (define-syntax tk/bind*
    (syntax-rules ()
      ((_ tag sequence (x ((y (lambda args body)) subst ...)))
       (tk/bind tag sequence `(,(lambda args
				  (tk-with-lock (lambda () body)))
			       subst ...)))
      ((_ tag sequence (list (lambda args body) subst ...))
       (tk/bind tag sequence `(,(lambda args
				  (tk-with-lock (lambda () body)))
			       subst ...)))
      ((_ tag sequence thunk)
       (tk/bind tag sequence (lambda () (tk-with-lock thunk))))))

  ;;; Bind the keypress event for WIDGET to PROC. ACTION must be a mapping
  ;;; listed in the group GROUP of the active keymap.
  (define (bind-key widget group action proc)
    (let ((mapping (inverse-key-binding group action)))
      (when mapping
	(tk/bind* widget mapping proc)
	(tk-eval (string-append "bind " (widget 'get-id)
				" " (symbol->string mapping)
				" +break")))))

  ;;; Create a tk image resource from a given PNG file.
  (define (tk/icon filename)
    (tk/image 'create 'photo format: "PNG"
	      file: (string-append "resources/icons/" filename)))


  ;; ---------------------------------------------------------------------------
  ;;; ## GUI Elements
  ;; ---------------------------------------------------------------------------

  ;;; A collection of classes and methods that make up Bintracker's internal
  ;;; GUI structure. All UI classes are derived from `<ui-element>`. The
  ;;; OOP system used is [coops](https://wiki.call-cc.org/eggref/5/coops).

  ;;; `<ui-element>` is a wrapper around Tk widgets. The widgets are wrapped in
  ;;; a Tk Frame widget. A `<ui-element>` instance may contain child elements,
  ;;; which are in turn instances of `<ui-element>. Any instance of
  ;;; `<ui-element>` or a derived class contains the following fields:
  ;;;
  ;;; - `setup` - an expression specifying how to construct the UI element.
  ;;; Details depend on the specific class type of the element. For standard
  ;;; `<ui-element>`s, this is the only mandatory field. Provides a reader named
  ;;; `ui-setup`.
  ;;;
  ;;; - `parent` - the Tk parent widget, typically a tk::frame. Defaults to `tk`
  ;;; if not specified. Provides an accessor named `ui-parent`.
  ;;;
  ;;; - `packing-args` - additional arguments that are passed to tk/pack when
  ;;; the UI element's main widget container is packed to the display.
  ;;;
  ;;; - `children` - an alist of child UI elements, where keys are symbols
  ;;; and values are instances of `<ui-element>` or a descendant class. Children
  ;;; are derived automatically from the `setup` field, so the user normally
  ;;; does not need to interact with the `children` field directly. Provides an
  ;;; accessor named `ui-children`.
  ;;;
  ;;; The generic procedures `ui-show`, `ui-hide`, and `ui-ref` are implemented
  ;;; for all UI element classes. UI elements commonly also provide
  ;;; `ui-set-state` and `ui-set-callbacks` methods.
  ;;;
  ;;; To implement your own custom UI elements, you should create a class
  ;;; that inherits from `<ui-element>` or one of its descendants. You probably
  ;;; want to define at least the `initialize-instance` method for your class,
  ;;; which should be an `after:` method. Note that `<ui-element>`'s constructor
  ;;; does not initialize the child elements. `ui-show`, however, will
  ;;; recursively apply `ui-show` on an `<ui-element>`. Therefore the `children`
  ;;; slot must not contain anything but named instances of `<ui-element>`,
  ;;; unless you override `ui-show` with your own **primary** method. The
  ;;; recommended way is to add new slots to your derived class for any custom
  ;;; widgets not derived from `<ui-element>`.
  (define-class <ui-element> ()
    ((initialized #f)
     (setup reader: ui-setup)
     (parent initform: tk accessor: ui-parent)
     (packing-args '())
     (box accessor: ui-box)
     (children initform: '() accessor: ui-children)))

  (define-method (initialize-instance after: (elem <ui-element>))
    (set! (ui-box elem) ((ui-parent elem) 'create-widget 'frame
			 style: 'BT.TFrame)))

  ;;; Map the GUI element to the display.
  (define-method (ui-show primary: (elem <ui-element>))
    (unless (slot-value elem 'initialized)
      (for-each (o ui-show cdr)
    		(ui-children elem))
      (set! (slot-value elem 'initialized) #t))
    (apply tk/pack (cons (ui-box elem)
			 (slot-value elem 'packing-args))))

  ;;; Remove the GUI element from the display.
  (define-method (ui-hide primary: (elem <ui-element>))
    (tk/pack 'forget (ui-box elem)))

  ;;; Returns ELEMs child UI element with the identifier CHILD-ELEMENT. The
  ;;; requested element may be a direct descendant of ELEM, or an indirect
  ;;; descendant in the tree of UI elements represented by ELEM.
  (define-method (ui-ref primary: (elem <ui-element>) child-element)
    (let ((children (ui-children elem)))
      (and (ui-children elem)
	   (or (alist-ref child-element children)
	       (find (lambda (child)
		       (ui-ref (cdr child) child-element))
		     children)))))

  ;;; A class representing a labelled Tk spinbox. Create instances with
  ;;;
  ;;; ```Scheme
  ;;; (make <ui-setting>
  ;;;       'parent PARENT
  ;;;       'setup '(LABEL INFO DEFAULT-VAR STATE-VAR FROM TO [CALLBACK]))
  ;;; ```
  ;;;
  ;;; where PARENT is the parent Tk widget, LABEL is the text of the label,
  ;;; INFO is a short description of the element's function, DEFAULT-VAR is a
  ;;; symbol denoting an entry in `(settings)`, STATE-VAR is a symbol denoting
  ;;; an entry in `(state)`, FROM and TO are integers describing the range of
  ;;; permitted values, and CALLBACK may optionally a procedure of no arguments
  ;;; that will be invoked when the user selects a new value.
  (define-class <ui-setting> (<ui-element>)
    ((packing-args '(side: left))
     label
     spinbox))

  (define-method (initialize-instance after: (buf <ui-setting>))
    (let* ((setup (ui-setup buf))
	   (default-var (third setup))
	   (state-var (fourth setup))
	   (from (fifth setup))
	   (to (sixth setup))
	   (callback (and (= 7 (length setup))
			  (seventh setup)))
	   (box (ui-box buf))
	   (spinbox (box 'create-widget 'spinbox from: from to: to
			 width: 4 state: 'disabled validate: 'none))
	   (validate-new-value
	    (lambda (new-val)
	      (if (and (integer? new-val)
		       (>= new-val from)
		       (<= new-val to))
		  (begin (set-state! state-var new-val)
		   	 (when callback (callback)))
		  (spinbox 'set (state state-var))))))
      (set! (slot-value buf 'label)
	(box 'create-widget 'label text: (car setup)
	     style: 'BT.TLabel foreground: (colors 'text)))
      ;; (tk/bind* spinbox '<<Increment>>
      ;; 	  (lambda ()
      ;; 	     (validate-new-value
      ;;               (add1 (string->number (spinbox 'get))))))
      ;; (tk/bind* spinbox '<<Decrement>>
      ;; 	  (lambda ()
      ;; 	     (validate-new-value
      ;;               (sub1 (string->number (spinbox 'get))))))
      (tk/bind* spinbox '<Return>
		(lambda ()
		  (validate-new-value (string->number (spinbox 'get)))
		  (switch-ui-zone-focus (state 'current-ui-zone))))
      (tk/bind* spinbox '<FocusOut>
		(lambda ()
		  (validate-new-value (string->number (spinbox 'get)))))
      (set! (slot-value buf 'spinbox) spinbox)
      (tk/pack (slot-value buf 'label) side: 'left padx: 5)
      (tk/pack spinbox side: 'left)
      (spinbox 'set (settings default-var))
      ;; TODO FIXME cannot currently re-implement this. Must defer
      ;; binding until `bind-info-status` is initialized. But that's
      ;; ok since we also need to separate callback bindings.
      ;; (bind-info-status label description)
      ))

  ;;; Set the state of the UI element `buf`. `state` can be either `'disabled`
  ;;; or `'enabled`.
  (define-method (ui-set-state primary: (buf <ui-setting>) state)
    ((slot-value buf 'spinbox) 'configure state: state))

  ;;; A wrapper for one or more `<ui-setting>`s. Create instances with
  ;;;
  ;;; ```Scheme
  ;;; (make <ui-settings-group> 'setup '((ID1 CHILD-SPEC ...) ...))
  ;;; ```
  ;;;
  ;;; where ID1 is a unique child element identifier, and CHILD-SPEC ... are the
  ;;; remaining arguments that will be passed to `<ui-setting>`'s constructor
  ;;; the `'setup` argument.
  (define-class <ui-settings-group> (<ui-element>)
    ((packing-args '(expand: 0 fill: x))))

  (define-method (initialize-instance after: (buf <ui-settings-group>))
    (set! (ui-children buf)
      (map (lambda (child)
	     (cons (car child)
		   (make <ui-setting>
		     'parent (ui-box buf) 'setup (cdr child))))
	   (ui-setup buf))))

  ;;; Enable or disable BUF. STATE must be either `'enabled` or `'disabled`.
  (define-method (ui-set-state primary: (buf <ui-settings-group>) state)
    (for-each (cute ui-set-state <> state)
	      (map cdr (ui-children buf))))

  ;;; A class representing a group of button widgets. Create instances with
  ;;;
  ;;; ```Scheme
  ;;; (make <ui-button-group> 'parent PARENT
  ;;;       'setup '((ID INFO ICON-FILE [INIT-STATE]) ...))
  ;;; ```
  ;;;
  ;;; where PARENT is the parent Tk widget, ID is a unique identifier, INFO is
  ;;; a string of text to be displayed in the status bar when the user hovers
  ;;; the button, ICON-FILE is the name of a file in *resources/icons/*. You
  ;;; may optionally set the initial state of the button (enabled/disabled) by
  ;;; specifying INIT-STATE.
  (define-class <ui-button-group> (<ui-element>)
    ((packing-args '(expand: 0 side: left))
     (orient 'horizontal)
     buttons))

  (define-method (initialize-instance after: (buf <ui-button-group>))
    (let ((orient (slot-value buf 'orient))
	  (box (ui-box buf)))
      (set! (slot-value buf 'buttons)
	(map (lambda (spec)
	       (cons (car spec)
		     (box 'create-widget 'button image: (tk/icon (third spec))
			  state: (or (and (= 4 (length spec)) (fourth spec))
				     'disabled)
			  style: "Toolbutton")))
	     (ui-setup buf)))
      (for-each (lambda (button)
		  (if (eqv? orient 'horizontal)
		      (tk/pack button side: 'left padx: 0 fill: 'y)
		      (tk/pack button side: 'top padx: 0 fill: 'x)))
		(map cdr (slot-value buf 'buttons)))
      (when (eqv? orient 'horizontal)
	(tk/pack (box 'create-widget 'separator orient: 'vertical)
		 side: 'left padx: 0 fill: 'y))))

  ;;; Enable or disable BUF or one of it's child elements. STATE must be either
  ;;; `'enabled` or `'disabled`. When passing a BUTTON-ID is specified, only the
  ;;; corresponding child element's state changes, otherwise, the change affects
  ;;; all buttons in the group.
  (define-method (ui-set-state primary: (buf <ui-button-group>)
			       state #!optional button-id)
    (if button-id
	(let ((button (alist-ref button-id (slot-value buf 'buttons))))
	  (when button (button 'configure state: state)))
	(for-each (lambda (button)
		    ((cdr button) 'configure state: state))
		  (slot-value buf 'buttons))))

  ;;; Set callback procedures for buttons in the button group. `callbacks`
  ;;; must be a list constructed as follows:
  ;;;
  ;;; `((ID THUNK) ...)`
  ;;;
  ;;; where ID is a button identifier, and THUNK is a callback procedure that
  ;;; takes no arguments. If ID is found in Bintracker's `global` key bindings
  ;;; table, the matching key binding information is added to the button's info
  ;;; text.
  (define-method (ui-set-callbacks primary: (buf <ui-button-group>)
				   callbacks)
    (let ((buttons (slot-value buf 'buttons)))
      (for-each (lambda (cb)
		  (let ((button (alist-ref (car cb) buttons)))
		    (when button
		      (button 'configure command: (cadr cb))
		      (bind-info-status
		       button
		       (string-append (car (alist-ref (car cb)
						      (ui-setup buf)))
			" " (key-binding->info 'global (car cb)))))))
		callbacks)))


  ;;; A class representing a toolbar metawidget, consisting of
  ;;; `<ui-button-group>`s. Create instances with
  ;;;
  ;;; ```Scheme
  ;;; (make <ui-toolbar> 'parent PARENT
  ;;;       'setup '((ID1 BUTTON-SPEC1 ...) ...))
  ;;; ```
  ;;;
  ;;; where PARENT is the parent Tk widget, ID1 is a unique identifier, and
  ;;; BUTTON-SPEC1 is a setup expression passed to <ui-button-group>.
  (define-class <ui-toolbar> (<ui-element>)
    ((packing-args '(expand: 0 fill: x))))

  (define-method (initialize-instance after: (buf <ui-toolbar>))
    (set! (ui-children buf)
      (map (lambda (spec)
	     (cons (car spec)
		   (make <ui-button-group> 'parent (ui-box buf)
			 'setup (cdr spec))))
	   (ui-setup buf))))

  ;;; Set callback procedures for buttons in the toolbar. `callbacks` must be
  ;;; a list constructed as follows:
  ;;;
  ;;; `(ID BUTTON-GROUP-CALLBACK-SPEC ...)`
  ;;;
  ;;; where ID is a button group identifier and BUTTON-GROUP-CALLBACK-SPEC is
  ;;; a callback specification as required by the `ui-set-callbacks` method of
  ;;; `<ui-button-group>`.
  (define-method (ui-set-callbacks primary: (buf <ui-toolbar>)
				   callbacks)
    (for-each (lambda (cb)
		(let ((group (alist-ref (car cb) (ui-children buf))))
		  (when group (ui-set-callbacks group (cdr cb)))))
	      callbacks))

  ;;; A class representing a container widget that wraps multiple resizable
  ;;; ui-buffers in a ttk
  ;;; [panedwindow](https://www.tcl.tk/man/tcl8.6/TkCmd/ttk_panedwindow.htm).
  ;;;
  ;;; Create instances with
  ;;;
  ;;; ```Scheme
  ;;; (make <ui-multibuffer> 'parent PARENT
  ;;;       'setup ((ID1 VISIBLE WEIGHT CHILD-SPEC ...) ...))
  ;;; ```
  ;;;
  ;;; where PARENT is the parent Tk widget (defaults to `tk`), ID1 is a unique
  ;;; identifier for a child buffer, VISIBLE is a boolean specifying if the
  ;;; child widget should initially be mapped to the display, WEIGHT is an
  ;;; integer specifying how large the child buffer should be in relation to the
  ;;; remaining child buffers, and CHILD-SPEC ... is the name of a UI buffer
  ;;; class, followed by the arguments that shall be passed to `make` when
  ;;; creating the child buffer instance.
  ;;;
  ;;; The optional ORIENT argument specifies the orientation of the metabuffer;
  ;;; it shall be one of the symbols `'vertical` or `'horizontal`. By default,
  ;;; metabuffers are oriented vertically, meaning new child buffers will be
  ;;; added below the current ones.
  ;;;
  ;;; The `state` slot contains an alist with the child identifiers as keys.
  ;;; `alist-ref` will return a list in the form (INDEX VISIBLE WEIGHT), where
  ;;; INDEX is an integer representing the position of the child element in the
  ;;; multibuffer, VISIBLE is `#t` if the child element is currently controlled
  ;;; by the display manager and `#f` otherwise, and WEIGHT is an integer
  ;;; specifying the initial size of the child element in relation to the other
  ;;; children (not taking into account resizes by the user),
  (define-class <ui-multibuffer> (<ui-element>)
    ((packing-args '(expand: 1 fill: both))
     (orient 'vertical)
     (setup '())
     state))  ;; id, index, visible, weigth

  ;; TODO: to properly hide a child, we must receive the "forget" event from
  ;; the child and act on it. Likewise, the "pack" event must propagate up.
  ;; Also collapse/expand events should likely propagate. Create virtual events
  ;; for collapse/expand/hide-child/show-child?

  (define-method (initialize-instance after: (buf <ui-multibuffer>))
    (set! (ui-box buf)
      ((ui-parent buf) 'create-widget 'panedwindow
       orient: (slot-value buf 'orient)))
    (set! (ui-children buf)
      (map (lambda (child)
	     (cons (car child)
		   (apply make (append (cdddr child)
				       `(parent ,(ui-box buf))))))
	   (ui-setup buf)))
    (set! (slot-value buf 'state)
      (map (lambda (child-spec idx)
	     (cons (car child-spec)
		   (cons idx (take (cdr child-spec) 2))))
	   (ui-setup buf)
	   (iota (length (ui-setup buf))))))

  ;;; Returns the actively managed children of BUF sorted by position.
  (define-method (multibuffer-active+sorted-children
		  primary: (buf <ui-multibuffer>))
    (let ((get-index (lambda (child)
		       (car (alist-ref (car child)
				       (slot-value buf 'state))))))
      (filter (lambda (child)
		(cadr (alist-ref (car child)
				 (slot-value buf 'state))))
	      (sort (ui-children buf)
		    (lambda (x1 x2)
		      (<= (get-index x1) (get-index x2)))))))

  (define-method (ui-show before: (buf <ui-multibuffer>))
    (unless (slot-value buf 'initialized)
      ;; TODO In theory, we could let `ui-show` of `<ui-element>` do the work,
      ;; but there seem to be some issues with Tk when adding children that
      ;; are not under control of the display manager yet.
      (for-each (o ui-show cdr)
		(ui-children buf))
      (for-each (lambda (child)
		  ((ui-box buf) 'add (ui-box (cdr child))
		   weight: (caddr (alist-ref (car child)
					     (slot-value buf 'state)))))
		(multibuffer-active+sorted-children buf))
      (set! (slot-value buf 'initialized) #t)))

  ;; (define-method (multibuffer-visibility primary: (buf <ui-multibuffer>)
  ;; 					 child visible)
  ;;   (let ((child-index (list-index (lambda (elem)
  ;; 				     (eqv? child (car elem)))
  ;; 				   (ui-children buf))))
  ;;     (when (and (slot-value buf 'initialized)
  ;; 		 ;; do not add to display again if already added
  ;; 		 (not (and visible (list-ref (slot-value buf 'visibility)
  ;; 					     child-index))))
  ;; 	((ui-box buf)
  ;; 	 (if visible 'add 'forget)
  ;; 	 (ui-box (alist-ref child (ui-children buf)))))
  ;;     (list-set! (slot-value buf 'visibility)
  ;; 		 child-index visible)))

  ;;; Add a new child buffer. CHILD-SPEC shall have the same form as the
  ;;; elements in the `'setup` argument to `(make <ui-multibuffer ...)`.
  ;;; The new child buffer will be added before the child named BEFORE, or at
  ;;; the end if BEFORE is not specified.
  (define-method (multibuffer-add primary: (buf <ui-multibuffer>)
				  child-spec #!key before)
    (when (alist-ref (car child-spec)
		     (ui-children buf))
      (error (string-append "Error: Child \"" (symbol->string (car child-spec))
			    " \" already exists.")))
    (set! (ui-children buf)
      (alist-update (car child-spec)
		    (apply make (append (cdddr child-spec)
					`(parent ,(ui-box buf))))
		    (ui-children buf)))
    (set! (slot-value buf 'state)
      (if before
	  (let ((before-child? (lambda (child-state)
				 (not (eqv? before (car child-state)))))
		(state (slot-value buf 'state)))
	    (map (lambda (child-state idx)
		   (cons (car child-state)
			 (cons idx (cddr child-state))))
		 (append (take-while before-child? state)
			 (list (cons (car child-spec)
				     (cons 0 (take (cdr child-spec) 2))))
			 (drop-while before-child? state))
		 (iota (+ 1 (length state)))))
	  (alist-update
	   (car child-spec)
	   (cons (length (slot-value buf 'state))
		 (take (cdr child-spec) 2))
	   (slot-value buf 'state))))
    (ui-show (alist-ref (car child-spec)
			(ui-children buf)))
    (when (and (slot-value buf 'initialized)
	       (caddr child-spec))
      ((ui-box buf) 'insert (if before (ui-box (ui-ref buf before)) 'end)
       (ui-box (ui-ref buf (car child-spec)))
       weight: (cadr (alist-ref (car child-spec)
				(slot-value buf 'state))))))

  ;; TODO Buffers should also be scrollable.
  ;;; This class commonly acts as a superclass for UI classes that represent
  ;;; user data. `<ui-buffer>`'s are collapsible. This means child elements are
  ;;; wrapped in a frame that the user can fold and unfold by clicking a button,
  ;;; or through a key binding. `<ui-repl> and many of the module display
  ;;; related widgets are based on this class.
  ;;;
  ;;; The constructor of this class does not evaluate `'setup` expressions, so
  ;;; derived classes should provide their own setup reader. A plain <ui-buffer>
  ;;; can be constructed with
  ;;;
  ;;; ```Scheme
  ;;; (make <ui-buffer> 'children ((ID1 . ELEMENT1) ...))
  ;;; ```
  ;;;
  ;;; where ID is a unique child element identifier, and ELEMENT1 is an
  ;;; instance of a `<ui-element>`.
  (define-class <ui-buffer> (<ui-element>)
    ((title "")
     (default-state 'expanded)
     expand-button
     collapse-button
     (collapse-proc #f)
     (expand-proc #f)
     content-box))

  (define-method (initialize-instance after: (buf <ui-buffer>))
    (set! (slot-value buf 'expand-button)
      (make <ui-button-group> 'parent (ui-box buf)
	    'setup '((expand "Expand buffer" "expand.png" 'enabled))
	    'orient 'vertical 'packing-args '(expand: 0 side: right fill: y)))
    (set! (slot-value buf 'collapse-button)
      (make <ui-button-group> 'parent (ui-box buf)
	    'setup '((collapse "Collapse buffer" "collapse.png" 'enabled))
	    'orient 'vertical 'packing-args '(expand: 0 side: right fill: y)))
    (set! (slot-value buf 'content-box)
      ((ui-box buf) 'create-widget 'frame style: 'BT.TFrame))
    (unless (slot-value buf 'collapse-proc)
      (set! (slot-value buf 'collapse-proc)
	(lambda (x)
	  (ui-hide (slot-value x 'collapse-button))
	  (ui-show (slot-value x 'expand-button)))))
    (unless (slot-value buf 'expand-proc)
      (set! (slot-value buf 'expand-proc)
	(lambda (x)
	  (ui-hide (slot-value x 'expand-button))
	  (ui-show (slot-value x 'collapse-button))))))

  (define-method (ui-show after: (buf <ui-buffer>))
    (ui-set-callbacks (slot-value buf 'expand-button)
		      `((expand ,(lambda () (ui-expand buf)))))
    (ui-set-callbacks (slot-value buf 'collapse-button)
		      `((collapse ,(lambda () (ui-collapse buf)))))
    (tk/pack (slot-value buf 'content-box) side: 'right expand: 1 fill: 'both)
    (ui-show (slot-value buf
			 (if (eqv? 'expanded (slot-value buf 'default-state))
			     'collapse-button
			     'expand-button))))

  ;; TODO these two should call (slot-value buf 'collapse/expand-proc)
  (define-method (ui-collapse primary: (buf <ui-buffer>))
    ((slot-value buf 'collapse-proc) buf))

  (define-method (ui-expand primary: (buf <ui-buffer>))
    ((slot-value buf 'expand-proc) buf))

  ;;; A welcome screen with two buttons for creating and opening an MDAL module,
  ;;; respectively. Create instances with `(make <ui-welcome-buffer>)`.
  (define-class <ui-welcome-buffer> (<ui-element>)
    ((packing-args '(expand: 1 fill: both))))

  (define-method (initialize-instance after: (buf <ui-welcome-buffer>))
    (let ((box (ui-box buf)))
      (tk/pack (box 'create-widget 'label text: "Welcome to Bintracker.")
	       padx: 20 pady: 20)
      (tk/pack (box 'create-widget 'button text: "Create new module..."))
      (tk/pack (box 'create-widget 'button text: "Open existing module..."))))

  ;;; A class representing a read-evaluate-print-loop prompt. `'setup` shall be
  ;;; the initial text to display on the prompt. To register the widget as
  ;;; focussable in the Bintracker main UI, specify a ui-zone identifier as
  ;;; initform to `'ui-zone`. The methods `repl-clear`, `repl-insert`, and
  ;;; `repl-get` are provided for interaction with the prompt.
  (define-class <ui-repl> (<ui-buffer>)
    ((ui-zone #f)
     repl
     yscroll
     (prompt "repl> ")
     (history '())))

  (define-method (initialize-instance after: (buf <ui-repl>))
    (set! (slot-value buf 'repl)
      ((slot-value buf 'content-box) 'create-widget 'text))
    (set! (slot-value buf 'yscroll)
      ((slot-value buf 'content-box) 'create-widget 'scrollbar orient: 'vertical))
    (when (slot-value buf 'ui-zone)
      (tk/bind* (slot-value buf 'repl) '<ButtonPress-1>
		(lambda () (switch-ui-zone-focus (slot-value buf 'ui-zone))))))

  ;; TODO this becomes a before: method once things are sorted out
  (define-method (ui-show primary: (buf <ui-repl>))
    (let ((repl (slot-value buf 'repl))
	  (yscroll (slot-value buf 'yscroll)))
      (unless (slot-value buf 'initialized)
	(repl 'configure  blockcursor: 'yes
	      bd: 0 highlightthickness: 0 bg: (colors 'background)
 	      fg: (colors 'text)
	      insertbackground: (colors 'text)
	      font: (list family: (settings 'font-mono)
			  size: (settings 'font-size)))
	(tk/pack yscroll side: 'right fill: 'y)
	(tk/pack repl expand: 1 fill: 'both side: 'right)
	(tk/pack (slot-value buf 'content-box) side: 'right fill: 'both)
	(configure-scrollbar-style yscroll)
	(yscroll 'configure command: `(,repl yview))
	(repl 'configure 'yscrollcommand: `(,yscroll set))
	(repl-insert buf (ui-setup buf))
	(repl-insert-prompt buf)
	(repl 'mark 'gravity "prompt" 'left)
	(repl 'see 'end)
	(bind-key (slot-value buf 'repl) 'console 'eval-console
		  (lambda () (repl-eval buf)))
	(bind-key (slot-value buf 'repl) 'console 'clear-console
		  (lambda () (repl-clear buf)))
	(set! (slot-value buf 'initialized) #t))))

  ;;; Insert STR at the end of the prompt of the `<ui-repl>` instance BUF.
  (define-method (repl-insert primary: (buf <ui-repl>) str)
    (let ((repl (slot-value buf 'repl)))
      (repl 'insert 'end str)
      (repl 'see 'insert)))

  (define-method (repl-insert-prompt primary: (buf <ui-repl>))
    (repl-insert buf (string-append "\n" (slot-value buf 'prompt)))
    ((slot-value buf 'repl) 'mark 'set "prompt" "end-1c"))

  ;;; Clear the prompt of the `<ui-repl>` instance BUF.
  (define-method (repl-clear primary: (buf <ui-repl>))
    ((slot-value buf 'repl) 'delete 0.0 'end)
    (repl-insert-prompt buf))

  ;;; Get the text contents of the `<ui-repl>` instance BUF. The remaining args
  ;;; are evaluated as arguments to `Tk:Text 'get`. See
  ;;; [Tk manual page](https://www.tcl.tk/man/tcl8.6/TkCmd/text.htm#M124).
  (define-method (repl-get primary: (buf <ui-repl>) #!rest args)
    (apply (slot-value buf 'repl) (cons 'get args)))

  ;;; Evaluate the latest command that the user entered into the repl prompt.
  (define-method (repl-eval primary: (buf <ui-repl>))
    (handle-exceptions
	exn
	(begin (repl-insert buf (string-append "\nError: " (->string exn)
					       (->string (arguments exn))))
	       (repl-insert-prompt buf))
      (let ((input-str (repl-get buf "prompt" "end-1c"))
	    (prompt (slot-value buf 'prompt)))
	(unless (string-null? input-str)
	  ;; TODO This is bad. We're relying on schemta's sexp parser here,
	  ;; which has it's own special requirements that may change. We should
	  ;; use a separate parser here (and it should probably be derived from
	  ;; scm2wiki as that's the most robust one).
	  (if (parse (any-of a-atom a-cons) input-str)
	      (begin
		(repl-insert
		 buf
		 (string-append
		  "\n" (->string (eval (read (open-input-string input-str))))))
		(repl-insert-prompt buf))
	      (repl-insert
	       buf
	       (string-append "\n"
			      (make-string (+ 3 (string-length prompt))))))
	  ((slot-value buf 'repl) 'see 'end)))))

  (define-method (ui-focus primary: (buf <ui-repl>))
    (tk/focus (slot-value buf 'repl)))

  ;;; A widget representing an MDAL group field instance. Create instances of
  ;;; this class with
  ;;;
  ;;; ```Scheme
  ;;; (make <ui-group-field> 'node-id ID 'parent-instance-path PATH)
  ;;; ```
  ;;;
  ;;; where ID is an MDAL field node identifier in `(current-config)` and PATH
  ;;; is an MDAL node path string that will be evaluated on `(current-mod)`.
  (define-class <ui-group-field> (<ui-element>)
    (label
     entry
     (node-id
      (error "Cannot create <ui-group-field> without node-id"))
     (parent-instance-path
      (error "Cannot create <ui-group-field> without parent-instance-path"))
     (packing-args '(expand: 0 fill: x))))

  (define-method (initialize-instance after: (buf <ui-group-field>))
    (let* ((node-id (slot-value buf 'node-id))
	   (color (get-field-color node-id)))
      (set! (slot-value buf 'label)
	((ui-box buf) 'create-widget 'label style: 'BT.TLabel
	 foreground: color text: (symbol->string node-id)
	 width: 12))
      (set! (slot-value buf 'entry)
	((ui-box buf) 'create-widget 'entry
	 bg: (colors 'row-highlight-minor) fg: color
	 bd: 0 highlightthickness: 0 insertborderwidth: 1
	 font: (list family: (settings 'font-mono)
		     size: (settings 'font-size)
		     weight: 'bold)))
      (tk/pack (slot-value buf 'label)
	       (slot-value buf 'entry)
	       side: 'left padx: 4 pady: 4)
      ((slot-value buf 'entry) 'insert 'end
       (normalize-field-value (cddr
    			       ((node-path
    				 (string-append
    				  (slot-value buf 'parent-instance-path)
    				  (symbol->string node-id)
    				  "/0/"))
    				(mdmod-global-node (current-mod))))
    			      node-id))))

  (define-method (ui-focus primary: (buf <ui-group-field>))
    (let ((entry (slot-value buf 'entry)))
      (entry 'configure bg: (colors 'cursor))
      (tk/focus entry)))

  (define-method (ui-unfocus primary: (buf <ui-group-field>))
    ((slot-value buf 'entry)
     'configure bg: (colors 'row-highlight-minor)))

  ;;; A wrapper for the group field nodes of an MDAL group instance. Create
  ;;; instances of this class with
  ;;;
  ;;; ```Scheme
  ;;; (make <ui-group-fields> 'group-id ID 'parent-instance-path PATH)
  ;;; ```
  ;;;
  ;;; where ID is an MDAL field node identifier in `(current-config)` and PATH
  ;;; is an MDAL node path string that will be evaluated on `(current-mod)`.
  (define-class <ui-group-fields> (<ui-buffer>)
    ((group-id
      (error "Cannot create <ui-group-fields> without group-id"))
     (parent-instance-path
      (error "Cannot create <ui-group-fields> without parent-instance-path"))
     (active-index 0)
     (packing-args '(expand: 0 fill: x))))

  (define-method (initialize-instance after: (buf <ui-group-fields>))
    (let ((subnode-ids
	   (config-get-subnode-type-ids (slot-value buf 'group-id)
					(current-config)
					'field)))
      (set! (ui-children buf)
	(map (lambda (field-id)
	       (cons field-id
		     (make <ui-group-field>
		       'parent (slot-value buf 'content-box)
		       'node-id field-id
		       'parent-instance-path
		       (slot-value buf 'parent-instance-path))))
	     subnode-ids))))

  ;; TODO expand: 1 fill: both?
  ;; bt-blockview -> <ui-basic-block-view>
  ;; packframe       content-frame
  ;; content-frame   block-frame
  ;; content-header  block-header
  ;; content-grid    block-content
  ;;; Abstract base class for `<ui-block-view>` and `<ui-order-view>`,
  ;;; implementing shared code for these two classes. Consider deriving from
  ;;; this class if you want to implement an alternative representation of an
  ;;; MDAL group's blocks.
  (define-class <ui-basic-block-view> (<ui-buffer>)
    ((group-id
      (error "Cannot create <ui-group-fields> without group-id"))
     field-ids
     field-configs
     header-frame
     content-frame
     rownum-frame
     rownum-header
     rownums
     block-frame
     block-header
     block-content
     xscroll
     yscroll
     (item-cache '())
     (packing-args '(expand: 0 fill: both))))

  (define-method (initialize-instance after: (buf <ui-basic-block-view>))
    (let ((content-box (slot-value buf 'content-box)))
      (set! (slot-value buf 'header-frame)
	(content-box 'create-widget 'frame style: 'BT.TFrame))
      (set! (slot-value buf 'content-frame)
	(content-box 'create-widget 'frame style: 'BT.TFrame))
      (set! (slot-value buf 'rownum-frame)
	((slot-value buf 'content-frame)
	 'create-widget 'frame style: 'BT.TFrame))
      (set! (slot-value buf 'block-frame)
	((slot-value buf 'content-frame)
	 'create-widget 'frame style: 'BT.TFrame))
      (set! (slot-value buf 'rownum-header)
	(textgrid-create-basic (slot-value buf 'rownum-frame)))
      (set! (slot-value buf 'rownums)
	(textgrid-create-basic (slot-value buf 'rownum-frame)))
      (set! (slot-value buf 'block-header)
	(textgrid-create-basic (slot-value buf 'block-frame)))
      (set! (slot-value buf 'block-content)
	(textgrid-create (slot-value buf 'block-frame)))
      (set! (slot-value buf 'xscroll)
	(content-box 'create-widget 'scrollbar orient: 'horizontal
		     command: `(,(slot-value buf 'block-content) xview)))
      (set! (slot-value buf 'yscroll)
	((slot-value buf 'content-frame)
	 'create-widget 'scrollbar orient: 'vertical
	 command: (lambda args
		    (apply (slot-value buf 'block-content) (cons 'yview args))
		    (apply (slot-value buf 'rownums) (cons 'yview args)))))))

  (define-method (ui-show before: (buf <ui-basic-block-view>))
    (unless (slot-value buf 'initialized)
      (let ((xscroll (slot-value buf 'xscroll))
	    (yscroll (slot-value buf 'yscroll))
	    (block-content (slot-value buf 'block-content)))
	(configure-scrollbar-style xscroll)
	(configure-scrollbar-style yscroll)
	(tk/pack xscroll fill: 'x side: 'bottom)
	(tk/pack (slot-value buf 'content-frame)
		 expand: 1 fill: 'both side: 'bottom)
	(tk/pack (slot-value buf 'header-frame) fill: 'x side: 'bottom)
	(tk/pack yscroll fill: 'y side: 'right)
	(tk/pack (slot-value buf 'rownum-frame) fill: 'y side: 'left)
	(tk/pack (slot-value buf 'rownum-header) padx: '(4 0) side: 'top)
	(tk/pack (slot-value buf 'rownums)
		 expand: 1 fill: 'y padx: '(4 0) side: 'top)
	(tk/pack (slot-value buf 'block-frame) fill: 'both side: 'right)
	(tk/pack (slot-value buf 'block-header) fill: 'x side: 'top)
	(ui-init-content-header buf)
	(tk/pack block-content expand: 1 fill: 'both side: 'top)
	(block-content 'configure xscrollcommand: `(,xscroll set)
		       yscrollcommand: `(,yscroll set))
	(block-content 'mark 'set 'insert "1.0")
	(ui-blockview-bind-events buf)
	(ui-blockview-update buf))))

  ;;; Generic procedure for mapping tags to the field columns of a textgrid.
  ;;; This can be used either on `block-header`, or on `block-content` slots.
  (define-method (ui-blockview-add-column-tags
		  primary: (buf <ui-basic-block-view>) textgrid row taglist)
    (for-each (lambda (tag field-config)
		(let ((start (bv-field-config-start field-config)))
		  (textgrid-add-tags textgrid tag row start
				     (+ start
					(bv-field-config-width field-config)))))
	      taglist
	      (map cadr (slot-value buf 'field-configs))))

  ;;; Add type tags to the given row in TEXTGRID. If TEXTGRID is not
  ;;; given, it defaults to the blockview's `block-content` slot.
  (define-method (ui-blockview-add-type-tags
		  primary: (buf <ui-basic-block-view>)
		  row #!optional (textgrid (slot-value buf 'block-content)))
    (ui-blockview-add-column-tags buf textgrid row
				  (map (o bv-field-config-type-tag cadr)
				       (slot-value buf 'field-configs))))

  ;;; Convert the list of row VALUES into a string that can be inserted into
  ;;; the blockview's content-grid or header-grid. Each entry in VALUES must
  ;;; correspond to a field column in the blockview's content-grid.
  (define-method (ui-blockview-values->string
		  primary: (buf <ui-basic-block-view>) values)
    (letrec ((construct-string
	      (lambda (str vals configs)
		(if (null-list? vals)
		    str
		    (let ((next-chunk
			   (string-append
			    str
			    (list->string
			     (make-list (- (bv-field-config-start (car configs))
					   (string-length str))
					#\space))
			    (->string (car vals)))))
		      (construct-string next-chunk (cdr vals)
					(cdr configs)))))))
      (construct-string "" values (map cadr (slot-value buf 'field-configs)))))

  ;;; Returns the position of the Tk text widget MARK as a list containing the
  ;;; row in car, and the character position in cadr. Row position is adjusted
  ;;; to 0-based indexing.
  (define-method (ui-blockview-mark->position
		  primary: (buf <ui-basic-block-view>) mark)
    (let ((pos (map string->number
		    (string-split ((slot-value buf 'block-content) 'index mark)
				  "."))))
      (list (sub1 (car pos))
	    (cadr pos))))

  ;;; Returns the current cursor position as a list containing the row in car,
  ;;; and the character position in cadr. Row position is adjusted to 0-based
  ;;; indexing.
  (define-method (ui-blockview-get-cursor-position primary:
						   (buf <ui-basic-block-view>))
    (ui-blockview-mark->position buf 'insert))

  ;;; Returns the current row, ie. the row that the cursor is currently on.
  (define-method (ui-blockview-get-current-row primary:
					       (buf <ui-basic-block-view>))
    (car (ui-blockview-get-cursor-position buf)))

  ;;; Returns the field ID that the cursor is currently on.
  (define-method (ui-blockview-get-current-field-id primary:
						    (buf <ui-basic-block-view>))
    (let ((char-pos (cadr (ui-blockview-get-cursor-position buf))))
      (list-ref (slot-value buf 'field-ids)
		(list-index
		 (lambda (cfg)
		   (and (>= char-pos (bv-field-config-start (cadr cfg)))
			(> (+ (bv-field-config-start (cadr cfg))
			      (bv-field-config-width (cadr cfg)))
			   char-pos)))
		 (slot-value buf 'field-configs)))))

  ;;; Returns the ID of the parent block node if the field that the cursor is
  ;;; currently on.
  (define-method (ui-blockview-get-current-block-id primary:
						    (buf <ui-basic-block-view>))
    (config-get-parent-node-id (ui-blockview-get-current-field-id buf)
			       (config-itree (current-config))))

  ;;; Returns the bv-field-configuration for the field that the cursor is
  ;;; currently on.
  (define-method (ui-blockview-get-current-field-config
		  primary: (buf <ui-basic-block-view>))
    (car (alist-ref (ui-blockview-get-current-field-id buf)
		    (slot-value buf 'field-configs))))

  ;;; Returns the MDAL command config for the field that the cursor is
  ;;; currently on.
  (define-method (ui-blockview-get-current-field-command
		  primary: (buf <ui-basic-block-view>))
    (config-get-inode-source-command (ui-blockview-get-current-field-id buf)
				     (current-config)))

  ;;; Returns the chunk from the item cache that the cursor is currently on.
  (define-method (ui-blockview-get-current-chunk primary:
						 (buf <ui-basic-block-view>))
    (list-ref (slot-value buf 'item-cache)
	      (ui-blockview-get-current-order-pos buf)))

  ;;; Determine the start and end positions of each item chunk in the
  ;;; blockview's item cache.
  (define-method (ui-blockview-start+end-positions primary:
						   (buf <ui-basic-block-view>))
    (letrec* ((get-positions
  	       (lambda (current-pos items)
  		 (if (null-list? items)
  		     '()
  		     (let ((len (length (car items))))
  		       (cons (list current-pos (+ current-pos (sub1 len)))
  			     (get-positions (+ current-pos len)
  					    (cdr items))))))))
      (get-positions 0 (slot-value buf 'item-cache))))

  ;;; Get the total number of rows of the blockview's contents.
  (define-method (ui-blockview-get-total-length primary:
						(buf <ui-basic-block-view>))
    (apply + (map length (slot-value buf 'item-cache))))

  ;;; Returns the active blockview zone as a list containing the first and last
  ;;; row in car and cadr, respectively.
  (define-method (ui-blockview-get-active-zone primary:
					       (buf <ui-basic-block-view>))
    (let ((start+end-positions (ui-blockview-start+end-positions buf))
	  (current-row (ui-blockview-get-current-row buf)))
      (list-ref start+end-positions
		(list-index (lambda (start+end)
			      (and (>= current-row (car start+end))
				   (<= current-row (cadr start+end))))
			    start+end-positions))))

  ;;; Return the field instance ID currently under cursor.
  (define-method (ui-blockview-get-current-field-instance
		  primary: (buf <ui-basic-block-view>))
    (- (ui-blockview-get-current-row buf)
       (car (ui-blockview-get-active-zone buf))))

  ;;; Return the index of the the current field node ID in the blockview's list
  ;;; of field IDs. The result can be used to retrieve a field instance value
  ;;; from a chunk in the item cache.
  (define-method (ui-blockview-get-current-field-index
		  primary: (buf <ui-basic-block-view>))
    (list-index (lambda (id)
		  (eq? id (ui-blockview-get-current-field-id buf)))
		(slot-value buf 'field-ids)))

  ;;; Returns the (un-normalized) value of the field instance currently under
  ;;; cursor.
  (define-method (ui-blockview-get-current-field-value
		  primary: (buf <ui-basic-block-view>))
    (list-ref (list-ref (ui-blockview-get-current-chunk buf)
			(ui-blockview-get-current-field-instance buf))
	      (ui-blockview-get-current-field-index buf)))

  ;;; Apply type tags and the `'active` tag to the current active zone of the
  ;;; blockview BUF.
  (define-method (ui-blockview-tag-active-zone primary:
					       (buf <ui-basic-block-view>))
    (let ((zone-limits (ui-blockview-get-active-zone buf))
	  (grid (slot-value buf 'block-content))
	  (rownums (slot-value buf 'rownums)))
      (textgrid-remove-tags-globally
       grid (cons 'active (map (o bv-field-config-type-tag cadr)
			       (slot-value buf 'field-configs))))
      (textgrid-remove-tags-globally rownums '(active txt))
      (textgrid-add-tags rownums '(active txt)
			 (car zone-limits)
			 0 'end (cadr zone-limits))
      (textgrid-add-tags grid 'active (car zone-limits)
			 0 'end (cadr zone-limits))
      (for-each (lambda (row)
		  (ui-blockview-add-type-tags buf row))
		(iota (- (cadr zone-limits)
			 (sub1 (car zone-limits)))
		      (car zone-limits) 1))))

  ;;; Update the row highlights of the blockview.
  (define-method (ui-blockview-update-row-highlights
		  primary: (buf <ui-basic-block-view>))
    (let* ((start-positions (map car (ui-blockview-start+end-positions buf)))
	   (minor-hl (state 'minor-row-highlight))
	   (major-hl (* minor-hl (state 'major-row-highlight)))
	   (make-rowlist
	    (lambda (hl-distance)
	      (flatten
	       (map (lambda (chunk start)
		      (map (cute + <> start)
			   (filter (lambda (i)
				     (zero? (modulo i hl-distance)))
				   (iota (length chunk)))))
		    (slot-value buf 'item-cache)
		    start-positions))))
	   (rownums (slot-value buf 'rownums))
	   (content (slot-value buf 'block-content)))
      (for-each (lambda (row)
      		  (textgrid-add-tags rownums 'rowhl-minor row)
      		  (textgrid-add-tags content 'rowhl-minor row))
      		(make-rowlist minor-hl))
      (for-each (lambda (row)
		  (textgrid-add-tags rownums 'rowhl-major row)
		  (textgrid-add-tags content 'rowhl-major row))
		(make-rowlist major-hl))))

  ;;; Perform a full update of the blockview `block-content`.
  (define-method (ui-blockview-update-content-grid primary:
						   (buf <ui-basic-block-view>))
    ((slot-value buf 'block-content) 'replace "0.0" 'end
     (string-intersperse (map (lambda (row)
				(ui-blockview-values->string
				 buf
				 (map (lambda (val id)
					(normalize-field-value val id))
				      row (slot-value buf 'field-ids))))
			      (concatenate (slot-value buf 'item-cache)))
			 "\n")))

  ;;; Update the blockview content grid on a row by row basis. This compares
  ;;; the NEW-ITEM-LIST against the current item cache, and only updates
  ;;; rows that have changed. The list length of NEW-ITEM-LIST and the
  ;;; lengths of each of the subchunks must match the list of items in the
  ;;; current item cache.
  ;;; This operation does not update the blockview's item cache, which should
  ;;; be done manually after calling this procedure.
  (define-method (ui-blockview-update-content-rows
		  primary: (buf <ui-basic-block-view>) new-item-list)
    (let ((grid (slot-value buf 'block-content)))
      (for-each (lambda (old-row new-row row-pos)
		  (unless (equal? old-row new-row)
		    (let* ((start (textgrid-position->tk-index row-pos 0))
			   (end (textgrid-position->tk-index row-pos 'end))
			   (tags (map string->symbol
				      (string-split (grid 'tag 'names start))))
			   (active-zone? (memq 'active tags))
			   (major-hl? (memq 'rowhl-major tags))
			   (minor-hl? (memq 'rowhl-minor tags)))
		      (grid 'replace start end
			    (ui-blockview-values->string
			     buf (map (lambda (val id)
					(normalize-field-value val id))
				      new-row (slot-value buf 'field-ids))))
		      (when major-hl?
			(grid 'tag 'add 'rowhl-major start end))
		      (when minor-hl?
			(grid 'tag 'add 'rowhl-minor start end))
		      (when active-zone?
			(ui-blockview-add-type-tags buf row-pos)))))
		(concatenate (slot-value buf 'item-cache))
		(concatenate new-item-list)
		(iota (length (concatenate new-item-list))))))

  ;;; Returns a list of character positions that the blockview's cursor may
  ;;; assume.
  (define-method (ui-blockview-cursor-x-positions primary:
						  (buf <ui-basic-block-view>))
    (flatten (map (lambda (field-cfg)
		    (map (cute + <> (bv-field-config-start field-cfg))
			 (iota (bv-field-config-cursor-digits field-cfg))))
		  (map cadr (slot-value buf 'field-configs)))))

  ;;; Show or hide the blockview's cursor. ACTION shall be `'add` or
  ;;; `'remove`.
  (define-method (ui-blockview-cursor-do primary: (buf <ui-basic-block-view>)
					 action)
    ((slot-value buf 'block-content) 'tag action 'active-cell "insert"
     (string-append "insert +"
		    (->string (bv-field-config-cursor-width
			       (ui-blockview-get-current-field-config buf)))
		    "c")))

  ;;; Hide the blockview's cursor.
  (define-method (ui-blockview-remove-cursor primary:
					     (buf <ui-basic-block-view>))
    (ui-blockview-cursor-do buf 'remove))

  ;;; Show the blockview's cursor.
  (define-method (ui-blockview-show-cursor primary:
					   (buf <ui-basic-block-view>))
    (ui-blockview-cursor-do buf 'add))

  ;;; Set the cursor to the given coordinates.
  (define-method (ui-blockview-set-cursor primary: (buf <ui-basic-block-view>)
					  row char)
    (let ((grid (slot-value buf 'block-content))
	  (active-zone (ui-blockview-get-active-zone buf)))
      (ui-blockview-remove-cursor buf)
      (grid 'mark 'set 'insert (textgrid-position->tk-index row char))
      (when (or (< row (car active-zone))
		(> row (cadr active-zone)))
	(ui-blockview-tag-active-zone buf))
      (ui-blockview-show-cursor buf)
      (grid 'see 'insert)
      ((slot-value buf 'rownums) 'see (textgrid-position->tk-index row 0))))

  ;;; Move the blockview's cursor in DIRECTION.
  (define-method (ui-blockview-move-cursor-common
		  primary: (buf <ui-basic-block-view>) direction step)
    (let* ((grid (slot-value buf 'block-content))
	   (current-pos (ui-blockview-get-cursor-position buf))
	   (current-row (car current-pos))
	   (current-char (cadr current-pos))
	   (total-length (ui-blockview-get-total-length buf)))
      (ui-blockview-set-cursor
       buf
       (case direction
	 ((Up) (if (zero? current-row)
		   (sub1 total-length)
		   (sub1 current-row)))
	 ((Down) (if (>= (+ step current-row) total-length)
		     0 (+ step current-row)))
	 ((Home) (if (zero? current-row)
		     current-row
		     (car (find (lambda (start+end)
				  (< (car start+end)
				     current-row))
				(reverse
				 (ui-blockview-start+end-positions buf))))))
	 ((End) (if (= current-row (sub1 total-length))
		    current-row
		    (let ((next-pos (find (lambda (start+end)
					    (> (car start+end)
					       current-row))
					  (ui-blockview-start+end-positions
					   buf))))
		      (if next-pos
			  (car next-pos)
			  (sub1 total-length)))))
	 (else current-row))
       (case direction
	 ((Left) (or (find (cute < <> current-char)
			   (reverse (ui-blockview-cursor-x-positions buf)))
		     (car (reverse (ui-blockview-cursor-x-positions buf)))))
	 ((Right) (or (find (cute > <> current-char)
			    (ui-blockview-cursor-x-positions buf))
		      0))
	 (else current-char)))
      (when (memv direction '(Left Right))
	(ui-blockview-update-current-command-info buf))))

  ;;; Set the input focus to the blockview BUF. In addition to setting the
  ;;; Tk focus, it also shows the cursor and updates the status bar info text.
  (define-method (ui-blockview-focus primary: (buf <ui-basic-block-view>))
    (ui-blockview-show-cursor buf)
    (tk/focus (slot-value buf 'block-content))
    (ui-blockview-update-current-command-info buf))

  ;;; Unset focus from the blockview BUF.
  (define-method (ui-blockview-unfocus primary: (buf <ui-basic-block-view>))
    (ui-blockview-remove-cursor buf)
    (set-state! 'active-md-command-info "")
    (reset-status-text!))

  ;;; Delete the field node instance that corresponds to the current cursor
  ;;; position, and insert an empty node at the end of the block instead.
  (define-method (ui-blockview-cut-current-cell primary:
						(buf <ui-basic-block-view>))
    (unless (null? (ui-blockview-get-current-field-value buf))
      (let ((action (list 'remove
			  (ui-blockview-get-current-block-instance-path buf)
			  (ui-blockview-get-current-field-id buf)
			  `((,(ui-blockview-get-current-field-instance buf))))))
	(push-undo (make-reverse-action action))
	(apply-edit! action)
	(ui-blockview-update buf)
	(ui-blockview-move-cursor buf 'Up)
	(run-post-edit-actions))))

  ;;; Insert an empty cell into the field column currently under cursor,
  ;;; shifting the following node instances down and dropping the last instance.
  (define-method (ui-blockview-insert-cell primary:
					   (buf <ui-basic-block-view>))
    (unless (null? (ui-blockview-get-current-field-value buf))
      (let ((action (list 'insert
			   (ui-blockview-get-current-block-instance-path buf)
			   (ui-blockview-get-current-field-id buf)
			   `((,(ui-blockview-get-current-field-instance buf)
			      ())))))
	(push-undo (make-reverse-action action))
	(apply-edit! action)
	(ui-blockview-update buf)
	(ui-blockview-show-cursor buf)
	(run-post-edit-actions))))

  ;;; Perform an edit action at cursor, assuming that the cursor points to a
  ;;; field that represents a note command.
  (define-method (ui-blockview-enter-note primary: (buf <ui-basic-block-view>)
					  keysym)
    (let ((note-val (keypress->note keysym)))
      (when note-val
	(ui-blockview-edit-current-cell buf note-val))))

  ;;; Perform an edit action at cursor, assuming that the cursor points to a
  ;;; field that represents a note command.
  (define-method (ui-blockview-enter-trigger primary:
					     (buf <ui-basic-block-view>))
    (ui-blockview-edit-current-cell buf #t))

  ;;; Perform an edit action at cursor, assuming that the cursor points to a
  ;;; field that represents a key/ukey command.
  (define-method (ui-blockview-enter-key primary: (buf <ui-basic-block-view>)
					 keysym)
    (display "key entry")
    (newline))

  ;;; Perform an edit action at cursor, assuming that the cursor points to a
  ;;; field that represents a numeric (int/uint) command.
  (define-method (ui-blockview-enter-numeric
		  primary: (buf <ui-basic-block-view>) keysym)
    (display "numeric entry")
    (newline))

  ;;; Perform an edit action at cursor, assuming that the cursor points to a
  ;;; field that represents a reference command.
  (define-method (ui-blockview-enter-reference
		  primary: (buf <ui-basic-block-view>) keysym)
    (display "reference entry")
    (newline))

  ;;; Perform an edit action at cursor, assuming that the cursor points to a
  ;;; field that represents a string command.
  (define-method (ui-blockview-enter-string
		  primary: (buf <ui-basic-block-view>) keysym)
    (display "string entry")
    (newline))

  ;;; Dispatch entry events occuring on the blockview's content grid to the
  ;;; appropriate edit procedures, depending on field command type.
  (define-method (ui-blockview-dispatch-entry-event
		  primary: (buf <ui-basic-block-view>) keysym)
    (unless (null? (ui-blockview-get-current-field-value buf))
      (let ((cmd (ui-blockview-get-current-field-command buf)))
	(if (command-has-flag? cmd 'is-note)
	    (ui-blockview-enter-note buf keysym)
	    (case (command-type cmd)
	      ((trigger) (ui-blockview-enter-trigger buf))
	      ((int uint) (ui-blockview-enter-numeric buf keysym))
	      ((key ukey) (ui-blockview-enter-key buf keysym))
	      ((reference) (ui-blockview-enter-reference buf keysym))
	      ((string) (ui-blockview-enter-string buf keysym)))))))

  ;;; Bind common event handlers for the blockview BUF.
  (define-method (ui-blockview-bind-events primary: (buf <ui-basic-block-view>))
    (let ((grid (slot-value buf 'block-content)))
      (tk/bind* grid '<<BlockMotion>>
		`(,(lambda (keysym)
		     (ui-blockview-move-cursor buf keysym))
		  %K))
      (tk/bind* grid '<Button-1>
		(lambda () (ui-blockview-set-cursor-from-mouse buf)))
      (tk/bind* grid '<<ClearStep>>
		(lambda ()
		  (unless (null? (ui-blockview-get-current-field-value buf))
		    (ui-blockview-edit-current-cell buf '()))))
      (tk/bind* grid '<<CutStep>>
		(lambda () (ui-blockview-cut-current-cell buf)))
      (tk/bind* grid '<<InsertStep>>
		(lambda () (ui-blockview-insert-cell buf)))
      (tk/bind* grid '<<BlockEntry>>
		`(,(lambda (keysym)
		     (ui-blockview-dispatch-entry-event buf keysym))
		  %K))))

  ;;; A class representing the display of an MDAL group node's blocks, minus the
  ;;; order block. Pattern display is implemented using this class.
  (define-class <ui-block-view> (<ui-basic-block-view>)
    (block-ids))

  (define-method (initialize-instance after: (buf <ui-block-view>))
    (let ((group-id (slot-value buf 'group-id)))
      (set! (slot-value buf 'block-ids)
	(remove (cute eq? <> (symbol-append group-id '_ORDER))
  		(config-get-subnode-type-ids group-id (current-config)
  					     'block)))
      (set! (slot-value buf 'field-ids)
	(flatten (map (cute config-get-subnode-ids <>
			    (config-itree (current-config)))
		      (slot-value buf 'block-ids))))
      (set! (slot-value buf 'field-configs)
	(blockview-make-field-configs (slot-value buf 'block-ids)
				      (slot-value buf 'field-ids)))))

  ;;; Set up the column and block header display.
  (define-method (ui-init-content-header primary: (buf <ui-block-view>))
    (let ((header (slot-value buf 'block-header))
  	  (field-ids (slot-value buf 'field-ids)))
      (header 'insert 'end
	      (string-append/shared
	       (string-intersperse
		(map (lambda (id)
		       (node-id-abbreviate
			id
			(apply + (map (o add1 bv-field-config-width cadr)
				      (filter
				       (lambda (field-config)
					 (memq (car field-config)
					       (config-get-subnode-ids
						id (config-itree
						    (current-config)))))
				       (slot-value buf 'field-configs))))))
		     (slot-value buf 'block-ids)))
  	       "\n"))
      (textgrid-add-tags header '(active txt) 0)
      (header 'insert 'end
	      (ui-blockview-values->string
	       buf
	       (map node-id-abbreviate
		    field-ids
		    (map (o bv-field-config-width cadr)
			 (slot-value buf 'field-configs)))))
      (textgrid-add-tags header 'active 1)
      (ui-blockview-add-type-tags buf 1 (slot-value buf 'block-header))))

  ;;; Returns the corresponding group order position for the chunk currently
  ;;; under cursor.
  (define-method (ui-blockview-get-current-order-pos primary:
						     (buf <ui-block-view>))
    (let ((current-row (ui-blockview-get-current-row buf)))
      (list-index (lambda (start+end)
		    (and (>= current-row (car start+end))
			 (<= current-row (cadr start+end))))
		  (ui-blockview-start+end-positions buf))))

  ;;; Update the command information in the status bar, based on the field that
  ;;; the cursor currently points to.
  (define-method (ui-blockview-update-current-command-info
		  primary: (buf <ui-block-view>))
    (set-active-md-command-info! (ui-blockview-get-current-field-id buf))
    (reset-status-text!))

  ;;; Get the up-to-date list of items to display. The list is nested. The first
  ;;; nesting level corresponds to an order position. The second nesting level
  ;;; corresponds to a row of fields. For order nodes, there is only one element
  ;;; at the first nesting level.
  (define-method (ui-blockview-get-item-list primary: (buf <ui-block-view>))
    (let* ((group-id (slot-value buf 'group-id))
  	   (group-instance (get-current-node-instance group-id))
  	   (order (mod-get-order-values group-id group-instance)))
      (map (lambda (order-pos)
	     (let ((block-values (mod-get-block-values group-instance
						       (cdr order-pos)))
		   (chunk-length (car order-pos)))
	       (if (<= chunk-length (length block-values))
		   (take block-values chunk-length)
		   (append block-values
			   (make-list (- chunk-length (length block-values))
				      (make-list (length (car block-values))
						 '()))))))
	   order)))

  ;;; Return the block instance ID currently under cursor.
  (define-method (ui-blockview-get-current-block-instance primary:
							  (buf <ui-block-view>))
    (let ((current-block-id (ui-blockview-get-current-block-id buf)))
      (list-ref (list-ref (map cdr
			       (mod-get-order-values
				(slot-value buf 'group-id)
				(get-current-node-instance
				 (slot-value buf 'group-id))))
			  (ui-blockview-get-current-order-pos buf))
		(list-index (lambda (block-id)
			      (eq? block-id current-block-id))
			    (slot-value buf 'block-ids)))))

  ;;; Return the MDAL node path string of the field currently under cursor.
  (define-method (ui-blockview-get-current-block-instance-path
		  primary: (buf <ui-block-view>))
    (string-append (get-current-instance-path (slot-value buf 'group-id))
		   (symbol->string (ui-blockview-get-current-block-id buf))
		   "/" (->string
			(ui-blockview-get-current-block-instance buf))))

  ;; TODO unify with specialization on ui-order-view
  ;;; Update the blockview row numbers according to the current item cache.
  (define-method (ui-blockview-update-row-numbers primary:
						  (buf <ui-block-view>))
    (let ((padding 4))
      ((slot-value buf 'rownums) 'replace "0.0" 'end
       (string-intersperse
	(flatten
	 (map (lambda (chunk)
		(map (lambda (i)
		       (string-pad-right
			(string-pad (number->string i (settings 'number-base))
				    padding #\0)
			(+ 2 padding)))
		     (iota (length chunk))))
	      (slot-value buf 'item-cache)))
	"\n"))))

  ;; TODO this relies on ui-zones, which are due to change
  ;; TODO can be unified with specialization on ui-order-view
  ;;; Set the blockview's cursor to the grid position currently closest to the
  ;;; mouse pointer.
  (define-method (ui-blockview-set-cursor-from-mouse primary:
						     (buf <ui-block-view>))
    (let ((mouse-pos (ui-blockview-mark->position buf 'current)))
      (unless (eq? 'blocks
		   (car (list-ref ui-zones (state 'current-ui-zone))))
	(switch-ui-zone-focus 'blocks))
      (ui-blockview-set-cursor buf (car mouse-pos)
			       (find (cute <= <> (cadr mouse-pos))
				     (reverse
				      (ui-blockview-cursor-x-positions buf))))
      (ui-blockview-update-current-command-info buf)))

  (define-method (ui-blockview-move-cursor primary: (buf <ui-block-view>)
					   direction)
    (ui-blockview-move-cursor-common buf direction
				     (if (zero? (state 'edit-step))
					 1 (state 'edit-step))))

  ;; TODO unify with specialization on ui-order-view?
  ;;; Set the field node instance that corresponds to the current cursor
  ;;; position to NEW-VALUE, and update the display and the undo/redo stacks
  ;;; accordingly.
  (define-method (ui-blockview-edit-current-cell primary: (buf <ui-block-view>)
						 new-value)
    (let ((action `(set ,(ui-blockview-get-current-block-instance-path buf)
			,(ui-blockview-get-current-field-id buf)
			((,(ui-blockview-get-current-field-instance buf)
			  ,new-value)))))
      (push-undo (make-reverse-action action))
      (apply-edit! action)
      ;; TODO might want to make this behaviour user-configurable
      (play-row (slot-value buf 'group-id)
		(ui-blockview-get-current-order-pos buf)
		(ui-blockview-get-current-field-instance buf))
      (ui-blockview-update buf)
      (unless (zero? (state 'edit-step))
	(ui-blockview-move-cursor buf 'Down))
      (run-post-edit-actions)))

  ;; TODO unify with specialization on ui-order-view
  ;; TODO storing/restoring insert mark position is a cludge. Generally we want
  ;; the insert mark to move if stuff is being inserted above it.
  ;;; Update the blockview display.
  ;;; The procedure attempts to be "smart" about updating, ie. it tries to not
  ;;; perform unnecessary updates. This makes the procedure fast enough to be
  ;;; used after any change to the blockview's content, rather than manually
  ;;; updating the part of the content that has changed.
  (define-method (ui-blockview-update primary: (buf <ui-block-view>))
    (let ((new-item-list (ui-blockview-get-item-list buf)))
      (unless (equal? new-item-list (slot-value buf 'item-cache))
	(let ((current-mark-pos ((slot-value buf 'block-content)
				 'index 'insert)))
	  (if (or (not (= (length new-item-list)
			  (length (slot-value buf 'item-cache))))
		  (not (equal? (map length new-item-list)
			       (map length (slot-value buf 'item-cache)))))
	      (begin
		(set! (slot-value buf 'item-cache) new-item-list)
		(ui-blockview-update-content-grid buf)
		(ui-blockview-update-row-numbers buf)
		((slot-value buf 'block-content)
		 'mark 'set 'insert current-mark-pos)
		(ui-blockview-tag-active-zone buf)
		(ui-blockview-update-row-highlights buf))
	      (begin
		(ui-blockview-update-content-rows buf new-item-list)
		((slot-value buf 'block-content)
		 'mark 'set 'insert current-mark-pos)
		(set! (slot-value buf 'item-cache) new-item-list)))))))

  (define-method (ui-show before: (buf <ui-block-view>))
    (unless (slot-value buf 'initialized)
      ((slot-value buf 'rownums)
       'configure width: 6 yscrollcommand: `(,(slot-value buf 'yscroll) set))
      ((slot-value buf 'rownum-header) 'configure height: 2 width: 6)
      ((slot-value buf 'block-header) 'configure height: 2)))

  ;;; A class representing the display of the order block of an MDAL group node
  ;;; instance.
  (define-class <ui-order-view> (<ui-basic-block-view>))

  (define-method (initialize-instance after: (buf <ui-order-view>))
    (let ((group-id (slot-value buf 'group-id)))
      (set! (slot-value buf 'field-ids)
  	(config-get-subnode-ids (symbol-append group-id '_ORDER)
  				(config-itree (current-config))))
      (set! (slot-value buf 'field-configs)
  	(blockview-make-field-configs (list (symbol-append group-id '_ORDER))
  				      (slot-value buf 'field-ids)))))

  ;; TODO rename -> blockview-init-content-header when old blockview code is
  ;; removed
  ;;; Set up the column and block header display.
  (define-method (ui-init-content-header primary: (buf <ui-order-view>))
    (let ((header (slot-value buf 'block-header))
  	  (field-ids (slot-value buf 'field-ids)))
      (header 'insert 'end
	      (ui-blockview-values->string
	       buf
	       (map node-id-abbreviate
		    (cons 'ROWS
			  (map (lambda (id)
				 (string->symbol
				  (string-drop (symbol->string id) 2)))
			       (cdr field-ids)))
		    (map (o bv-field-config-width cadr)
			 (slot-value buf 'field-configs)))))
      (textgrid-add-tags header 'active 0)
      (ui-blockview-add-type-tags buf 0 (slot-value buf 'block-header))))

  ;;; Returns the corresponding group order position for the chunk currently
  ;;; under cursor. Alias for `ui-blockview-get-current-row`.
  (define-method (ui-blockview-get-current-order-pos primary:
						     (buf <ui-order-view>))
    (ui-blockview-get-current-row buf))

  ;;; Update the command information in the status bar, based on the field that
  ;;; the cursor currently points to.
  (define-method (ui-blockview-update-current-command-info
		  primary: (buf <ui-order-view>))
    (let ((current-field-id (ui-blockview-get-current-field-id buf)))
      (set-state! 'active-md-command-info
		  (if (symbol-contains current-field-id "_LENGTH")
		      "Step Length"
		      (string-append "Channel "
				     (string-drop (symbol->string
						   current-field-id)
						  2))))
      (reset-status-text!)))

  ;;; Get the up-to-date list of items to display. The list is nested. The first
  ;;; nesting level corresponds to an order position. The second nesting level
  ;;; corresponds to a row of fields. For order nodes, there is only one element
  ;;; at the first nesting level.
  (define-method (ui-blockview-get-item-list primary: (buf <ui-order-view>))
    (let ((group-id (slot-value buf 'group-id)))
      (list (mod-get-order-values group-id
				  (get-current-node-instance group-id)))))

  ;;; Update the blockview row numbers according to the current item cache.
  (define-method (ui-blockview-update-row-numbers primary:
						  (buf <ui-order-view>))
    (let ((padding 3))
      ((slot-value buf 'rownums) 'replace "0.0" 'end
       (string-intersperse
	(flatten
	 (map (lambda (chunk)
		(map (lambda (i)
		       (string-pad-right
			(string-pad (number->string i (settings 'number-base))
				    padding #\0)
			(+ 2 padding)))
		     (iota (length chunk))))
	      (slot-value buf 'item-cache)))
	"\n"))))

  ;; TODO this relies on ui-zones, which are due to change
  ;;; Set the blockview's cursor to the grid position currently closest to the
  ;;; mouse pointer.
  (define-method (ui-blockview-set-cursor-from-mouse primary:
						     (buf <ui-order-view>))
    (let ((mouse-pos (ui-blockview-mark->position buf 'current)))
      (unless (eq? 'order
		   (car (list-ref ui-zones (state 'current-ui-zone))))
	(switch-ui-zone-focus 'order))
      (ui-blockview-set-cursor buf (car mouse-pos)
			       (find (cute <= <> (cadr mouse-pos))
				     (reverse
				      (ui-blockview-cursor-x-positions buf))))
      (ui-blockview-update-current-command-info buf)))

  (define-method (ui-blockview-move-cursor primary: (buf <ui-order-view>)
					   direction)
    (ui-blockview-move-cursor-common buf direction 1))

  ;;; Set the field node instance that corresponds to the current cursor
  ;;; position to NEW-VALUE, and update the display and the undo/redo stacks
  ;;; accordingly.
  (define-method (ui-blockview-edit-current-cell primary: (buf <ui-order-view>)
						 new-value)
    (let ((action `(set ,(ui-blockview-get-current-block-instance-path buf)
			,(ui-blockview-get-current-field-id buf)
			((,(ui-blockview-get-current-field-instance buf)
			  ,new-value)))))
      (push-undo (make-reverse-action action))
      (apply-edit! action)
      (ui-blockview-update buf)
      (unless (zero? (state 'edit-step))
	(ui-blockview-move-cursor buf 'Down))
      (run-post-edit-actions)))

  ;; TODO storing/restoring insert mark position is a cludge. Generally we want
  ;; the insert mark to move if stuff is being inserted above it.
  ;;; Update the blockview display.
  ;;; The procedure attempts to be "smart" about updating, ie. it tries to not
  ;;; perform unnecessary updates. This makes the procedure fast enough to be
  ;;; used after any change to the blockview's content, rather than manually
  ;;; updating the part of the content that has changed.
  (define-method (ui-blockview-update primary: (buf <ui-order-view>))
    (let ((new-item-list (ui-blockview-get-item-list buf)))
      (unless (equal? new-item-list (slot-value buf 'item-cache))
	(let ((current-mark-pos ((slot-value buf 'block-content)
				 'index 'insert)))
	  (if (or (not (= (length new-item-list)
			  (length (slot-value buf 'item-cache))))
		  (not (equal? (map length new-item-list)
			       (map length (slot-value buf 'item-cache)))))
	      (begin
		(set! (slot-value buf 'item-cache) new-item-list)
		(ui-blockview-update-content-grid buf)
		(ui-blockview-update-row-numbers buf)
		((slot-value buf 'block-content)
		 'mark 'set 'insert current-mark-pos)
		(ui-blockview-tag-active-zone buf))
	      (begin
		(ui-blockview-update-content-rows buf new-item-list)
		((slot-value buf 'block-content)
		 'mark 'set 'insert current-mark-pos)
		(set! (slot-value buf 'item-cache) new-item-list)))))))

  (define-method (ui-show before: (buf <ui-order-view>))
    (unless (slot-value buf 'initialized)
      ((slot-value buf 'rownums)
       'configure width: 5 yscrollcommand: `(,(slot-value buf 'yscroll) set))
       ((slot-value buf 'rownum-header) 'configure height: 1 width: 5)
       ((slot-value buf 'block-header) 'configure height: 1)))


  ;;; A widget class suitable for displaying an MDAL group node's block members.
  ;;; It is a wrapper around a <ui-block-view> and the associated
  ;;; <ui-order-view>. Create instances with
  ;;;
  ;;; ```Scheme
  ;;; (make <ui-group-blocks> 'group-id ID)
  ;;; ```
  ;;;
  ;;; where ID is the identifier of the group in `(current-module)` to display.
  (define-class <ui-blocks> (<ui-multibuffer>)
    ((orient 'horizontal)
     (group-id (error "Cannot construct <ui-group-blocks> without group-id."))))

  (define-method (initialize-instance after: (buf <ui-blocks>))
    (multibuffer-add buf `(blocks #t 2 ,<ui-block-view> group-id
				  ,(slot-value buf 'group-id)))
    (multibuffer-add buf `(order #t 1 ,<ui-order-view> group-id
				 ,(slot-value buf 'group-id))))

  (define-class <ui-subgroups> (<ui-buffer>)
    ((packing-args '(expand: 1 fill: both))
     (group-id (error "Cannot construct <ui-subgroups> without a group-id."))
     tabs
     subgroups))

  (define-method (initialize-instance after: (buf <ui-subgroups>))
    (set! (slot-value buf 'tabs)
      ((slot-value buf 'content-box)
       'create-widget 'notebook style: 'BT.TNotebook))
    (set! (slot-value buf 'subgroups)
      (map (lambda (id)
	     (cons id (make <ui-group> 'group-id id)))
	   (config-get-subnode-type-ids (slot-value buf 'group-id)
					(current-config)
					'group)))
    (for-each (lambda (subgroup)
		((slot-value buf 'tabs) 'add (ui-box (cdr subgroup))
		 text: (symbol->string (car subgroup))))
	      (slot-value buf 'subgroups)))

  (define-method (ui-show before: (buf <ui-subgroups>))
    (tk/pack (slot-value buf 'tabs) expand: 1 fill: 'both))

  (define-class <ui-group> (<ui-multibuffer>)
    (group-id))

  (define-method (initialize-instance after: (buf <ui-group>))
    (let ((group-id (slot-value buf 'group-id)))
      (unless (null? (config-get-subnode-type-ids
		      group-id (current-config) 'field))
	(multibuffer-add
	 buf
	 `(fields #t 1 ,<ui-group-fields> group-id ,group-id
		  parent-instance-path
		  ;; TODO handle groups with multiple instances
		  ,(if (eqv? group-id 'GLOBAL)
		       "0/"
		       (string-append
			"0/"
			(string-concatenate
			 (map (lambda (id)
				(string-append (symbol->string id)
					       "/0/"))
			      (reverse
			       (cdr (config-get-node-ancestors-ids
				     group-id
				     (config-itree (current-config))))))))))))
      (unless (null? (config-get-subnode-type-ids
		      group-id (current-config) 'block))
	(multibuffer-add buf `(blocks #t 2 ,<ui-blocks> group-id ,group-id)))
      (unless (null? (config-get-subnode-type-ids
		      group-id (current-config) 'group))
        (multibuffer-add buf `(subgroups #t 2 ,<ui-subgroups>
					 group-id ,group-id)))))

  ;; ---------------------------------------------------------------------------
  ;;; ## Dialogues
  ;; ---------------------------------------------------------------------------

  ;;; This section provides abstractions over Tk dialogues and pop-ups. This
  ;;; includes both native Tk widgets and Bintracker-specific metawidgets.
  ;;; `tk/safe-dialogue` and `custom-dialog` are potentially the most useful
  ;;; entry points for creating native resp. custom dialogues from user code,
  ;;; eg. when calling from a plugin.

  ;;; Used to provide safe variants of tk/message-box, tk/get-open-file, and
  ;;; tk/get-save-file that block the main application window  while the pop-up
  ;;; is alive. This is a work-around for tk dialogue procedures getting stuck
  ;;; once they lose focus. tk-with-lock does not help in these cases.
  (define (tk/safe-dialogue type . args)
    (tk-eval "tk busy .")
    (tk/update)
    (let ((result (apply type args)))
      (tk-eval "tk busy forget .")
      result))

  ;;; Crash-safe variant of `tk/message-box`.
  (define (tk/message-box* . args)
    (apply tk/safe-dialogue (cons tk/message-box args)))

  ;;; Crash-safe variant of `tk/get-open-file`.
  (define (tk/get-open-file* . args)
    (apply tk/safe-dialogue (cons tk/get-open-file args)))

  ;;; Crash-safe variant of `tk/get-save-file`.
  (define (tk/get-save-file* . args)
    (apply tk/safe-dialogue (cons tk/get-save-file args)))

  ;;; Display the "About Bintracker" message.
  (define (about-message)
    (tk/message-box* title: "About"
		     message: (string-append "Bintracker\nversion "
					     *bintracker-version*)
		     detail: "Dedicated to Ján Deák"
		     type: 'ok))

  ;;; Display a message box that asks the user whether to save unsaved changes
  ;;; before exiting or closing. EXIT-OR-CLOSING should be the string
  ;;; `"exit"` or `"closing"`, respectively.
  (define (exit-with-unsaved-changes-dialog exit-or-closing)
    (tk/message-box* title: (string-append "Save before "
					   exit-or-closing "?")
		     default: 'yes
		     icon: 'warning
		     parent: tk
		     message: (string-append "There are unsaved changes. "
					     "Save before " exit-or-closing
					     "?")
		     type: 'yesnocancel))

  ;; TODO instead of destroying, should we maybe just tk/forget?
  ;;; Create a custom dialogue user dialogue popup. The dialogue widget sets up
  ;;; a default widget layout with `Cancel` and `Confirm` buttons and
  ;;; corresponding key handlers for `<Escape>` and `<Return>`.
  ;;;
  ;;; Returns a procedure *P*, which can be called as follows:
  ;;;
  ;;; `(P 'show)`
  ;;;
  ;;; Display the dialogue widget. Call this procedure **before** you add any
  ;;; user-defined widgets, bindings, procedures, and finalizers.
  ;;;
  ;;; `(P 'add 'widget ID WIDGET-SPECIFICATION)`
  ;;;
  ;;; Add a widget named ID, where WIDGET-SPECIFICATION is the list of
  ;;; widget arguments that will be passed to Tk as the remaining arguments of
  ;;; a call to `(parent 'create-widget ...)`.
  ;;;
  ;;; `(P 'add 'binding EVENT PROC)`
  ;;;
  ;;; Bind PROC to the Tk event sequence specifier EVENT.
  ;;;
  ;;; `(P 'add 'procedure ID PROC)`
  ;;;
  ;;; Add a custom procedure ;; TODO redundant?
  ;;;
  ;;; `(P 'add 'finalizer PROC)`
  ;;;
  ;;; Add PROC to the list of finalizers that will run on a successful exit from
  ;;; the dialogue.
  ;;;
  ;;; `(P 'ref ID)`
  ;;; Returns the user-defined widget or procedure named ID. Use this to
  ;;; cross-reference elements created with `(c 'add [widget|procedure])` within
  ;;; user code.
  ;;;
  ;;; `(P 'destroy)`
  ;;;
  ;;; Executes any user defined finalizers, then destroys the dialogue window.
  ;;; You normally do not need to call this explicitly unless you are handling
  ;;; exceptions.
  (define (make-dialogue)
    (let* ((tl #f)
	   (widgets '())
	   (procedures '())
	   (get-ref (lambda (id)
		      (let ((ref (alist-ref id (append widgets procedures))))
			(and ref (car ref)))))
	   (extra-finalizers '())
	   (finalize (lambda (success)
		       (when success
			 (for-each (lambda (x) (x)) extra-finalizers))
		       (tk/destroy tl))))
      (lambda args
	(case (car args)
	  ((show)
	   (unless tl
	     (set! tl (tk 'create-widget 'toplevel))
	     ;; TODO appears to have no effect
	     ;; (tk/wm 'attributes tl type: 'dialog)
	     (set! widgets `((content ,(tl 'create-widget 'frame))
			     (footer ,(tl 'create-widget 'frame))))
	     (set! widgets
	       (append widgets
		       `((confirm ,((get-ref 'footer) 'create-widget
				    'button text: "Confirm"
				    command: (lambda () (finalize #t))))
			 (cancel ,((get-ref 'footer) 'create-widget
				   'button text: "Cancel"
				   command: (lambda () (finalize #f)))))))
	     (tk/bind tl '<Escape> (lambda () (finalize #f)))
	     (tk/bind tl '<Return> (lambda () (finalize #t)))
	     (tk/pack (get-ref 'confirm) side: 'right)
	     (tk/pack (get-ref 'cancel) side: 'right)
	     (tk/pack (get-ref 'content) side: 'top)
	     (tk/pack (get-ref 'footer) side: 'top)))
	  ((add)
	   (case (cadr args)
	     ((binding) (apply tk/bind (cons tl (cddr args))))
	     ((finalizer) (set! extra-finalizers
			    (cons (caddr args) extra-finalizers)))
	     ((widget) (let ((user-widget (apply (get-ref 'content)
						 (cons 'create-widget
						       (cadddr args)))))
			 (set! widgets (cons (list (caddr args) user-widget)
					     widgets))
			 (tk/pack user-widget side: 'top)))
	     ((procedure)
	      (set! procedures (cons (caddr args) procedures)))))
	  ((ref) (get-ref (cadr args)))
	  ((destroy)
	   (when tl
	     (finalize #f)
	     (set! tl #f)))
	  (else (warning (string-append "Error: Unsupported dialog action"
					(->string args))))))))


  ;; ---------------------------------------------------------------------------
  ;;; ## Widget Style
  ;; ---------------------------------------------------------------------------

  ;;; Configure ttk widget styles.
  (define (update-ttk-style)
    (ttk/style 'configure 'BT.TFrame background: (colors 'background))

    (ttk/style 'configure 'BT.TLabel background: (colors 'background)
	       foreground: (colors 'text)
	       font: (list family: (settings 'font-mono)
			   size: (settings 'font-size)
			   weight: 'bold))

    (ttk/style 'configure 'BT.TNotebook background: (colors 'background))
    (ttk/style 'configure 'BT.TNotebook.Tab
	       background: (colors 'background)
	       font: (list family: (settings 'font-mono)
			   size: (settings 'font-size)
			   weight: 'bold)))

  ;;; Configure the style of the scrollbar widget S to match Bintracker's
  ;;; style.
  (define (configure-scrollbar-style s)
    (s 'configure bd: 0 highlightthickness: 0 relief: 'flat
       activebackground: (colors 'row-highlight-major)
       bg: (colors 'row-highlight-minor)
       troughcolor: (colors 'background)
       elementborderwidth: 0))


  ;; ---------------------------------------------------------------------------
  ;;; ## Events
  ;; ---------------------------------------------------------------------------

  ;;; Disable automatic keyboard traversal. Needed because it messes with key
  ;;; binding involving Tab.
  (define (disable-keyboard-traversal)
    (tk/event 'delete '<<NextWindow>>)
    (tk/event 'delete '<<PrevWindow>>))

  ;;; Create default virtual events for Bintracker. This procedure only needs
  ;;; to be called on startup, or after updating key bindings.
  (define (create-virtual-events)
    (apply tk/event (append '(add <<BlockEntry>>)
			    (map car
				 (app-keys-note-entry (settings 'keymap)))))
    (tk/event 'add '<<BlockMotion>>
	      '<Up> '<Down> '<Left> '<Right> '<Home> '<End>)
    (tk/event 'add '<<ClearStep>> (inverse-key-binding 'edit 'clear-step))
    (tk/event 'add '<<CutStep>> (inverse-key-binding 'edit 'cut-step))
    (tk/event 'add '<<CutRow>> (inverse-key-binding 'edit 'cut-row))
    (tk/event 'add '<<InsertRow>> (inverse-key-binding 'edit 'insert-row))
    (tk/event 'add '<<InsertStep>> (inverse-key-binding 'edit 'insert-step)))

  ;;; Reverse the evaluation order for tk bindings, so that global bindings are
  ;;; evaluated before the local bindings of WIDGET. This is necessary to
  ;;; prevent keypresses that are handled globally being passed through to the
  ;;; widget.
  (define (reverse-binding-eval-order widget)
    (let ((widget-id (widget 'get-id)))
      (tk-eval (string-append "bindtags " widget-id " {all . "
			      (tk/winfo 'class widget)
			      " " widget-id "}"))))


  ;; ---------------------------------------------------------------------------
  ;;; ## Menus
  ;; ---------------------------------------------------------------------------

  ;; `submenus` shall be an alist, where keys are unique identifiers, and
  ;; values are the actual tk menus.

  (defstruct menu
    ((widget (tk 'create-widget 'menu)) : procedure)
    ((items '()) : list))

  ;;; Destructively add an item to menu-struct `menu` according to
  ;;; `item-spec`. `item-spec` must be a list containing either
  ;;; - `('separator)`
  ;;; - `('command id label underline accelerator command)`
  ;;; - `('submenu id label underline items-list)`
  ;;; where *id*  is a unique identifier symbol; *label* and *underline* are the
  ;;; name that will be shown in the menu for this item, and its underline
  ;;; position; *accelerator* is a string naming a keyboard shortcut for the
  ;;; item, command is a procedure to be associated with the item, and
  ;;; items-list is a list of item-specs.
  (define (add-menu-item! menu item-spec)
    ;; TODO add at position (insert)
    (let ((append-to-item-list!
	   (lambda (id item)
	     (menu-items-set! menu (append (menu-items menu)
					   (list id item))))))
      (case (car item-spec)
	((command)
	 (append-to-item-list! (second item-spec) #f)
	 ((menu-widget menu) 'add 'command label: (third item-spec)
	  underline: (fourth item-spec)
	  accelerator: (or (fifth item-spec) "")
	  command: (sixth item-spec)))
	((submenu)
	 (let* ((submenu (construct-menu (fifth item-spec))))
	   (append-to-item-list! (second item-spec)
				 submenu)
	   ((menu-widget menu) 'add 'cascade
	    menu: (menu-widget submenu)
	    label: (third item-spec)
	    underline: (fourth item-spec))))
	((separator)
	 (append-to-item-list! 'separator #f)
	 ((menu-widget menu) 'add 'separator))
	(else (error (string-append "Unknown menu item type \""
				    (->string (car item-spec))
				    "\""))))))

  (define (construct-menu items)
    (let* ((my-menu (make-menu widget: (tk 'create-widget 'menu))))
      (for-each (lambda (item)
		  (add-menu-item! my-menu item))
		items)
      my-menu))


  ;; ---------------------------------------------------------------------------
  ;;; ## Top Level Layout
  ;; ---------------------------------------------------------------------------

  ;;; The core widgets that make up Bintracker's GUI.

  (define main-panes (tk 'create-widget 'panedwindow))

  (define main-frame (main-panes 'create-widget 'frame))

  (define console-frame (main-panes 'create-widget 'frame))

  (define status-frame (tk 'create-widget 'frame))

  ;; TODO take into account which zones are actually active
  ;;; The list of all ui zones that can be focussed. The list consists of a list
  ;;; for each zone, which contains the focus procedure in car, and the unfocus
  ;;; procedure in cadr.
  (define ui-zones
    `((fields ,(lambda () (focus-fields-widget (current-fields-view)))
	      ,(lambda () (unfocus-fields-widget (current-fields-view))))
      (blocks ,(lambda () (blockview-focus (current-blocks-view)))
      	      ,(lambda () (blockview-unfocus (current-blocks-view))))
      (order ,(lambda () (blockview-focus (current-order-view)))
      	     ,(lambda () (blockview-unfocus (current-order-view))))
      (console ,(lambda () (ui-focus console))
	       ,(lambda () '()))))

  ;;; Switch keyboard focus to another UI zone. `new-zone` can be either an
  ;;; index to the `ui-zones` list, or a symbol naming an entry in
  ;;; that list.
  (define (switch-ui-zone-focus new-zone)
    (let ((new-zone-index (or (and (integer? new-zone)
				   new-zone)
			      (list-index (lambda (zone)
					    (eq? new-zone (car zone)))
					  ui-zones))))
      ;; TODO find a better way of preventing focussing/unfocussing unpacked
      ;; widgets
      (when (current-mod)
	((third (list-ref ui-zones (state 'current-ui-zone)))))
      (set-state! 'current-ui-zone new-zone-index)
      ((second (list-ref ui-zones new-zone-index)))))

  ;;; Unfocus the currently active UI zone, and focus the next one listed in
  ;;; ui-zones.
  (define (focus-next-ui-zone)
    (let* ((current-zone (state 'current-ui-zone))
	   (next-zone (if (= current-zone (sub1 (length ui-zones)))
			  0 (+ 1 current-zone))))
      (switch-ui-zone-focus next-zone)))

  ;;; Unfocus the currently active UI zone, and focus the previous one listed in
  ;;; ui-zones.
  (define (focus-previous-ui-zone)
    (let* ((current-zone (state 'current-ui-zone))
	   (prev-zone (if (= current-zone 0)
			  (sub1 (length ui-zones))
			  (sub1 current-zone))))
      (switch-ui-zone-focus prev-zone)))


  ;; ---------------------------------------------------------------------------
  ;;; ## Toolbar
  ;; ---------------------------------------------------------------------------

  ;; TODO this should move to bintracker-core.

  (define main-toolbar
    (make <ui-toolbar> 'setup
     '((file (new-file "New File" "new.png" enabled)
	     (load-file "Load File..." "load.png" enabled)
	     (save-file "Save File" "save.png"))
       (journal (undo "Undo last edit" "undo.png")
		(redo "Redo last edit" "redo.png"))
       (edit (copy "Copy Selection" "copy.png")
      	     (cut "Cut Selection (delete with shift)" "cut.png")
      	     (clear "Clear Selection (delete, no shift)" "clear.png")
      	     (paste "Paste from Clipboard (no shift)" "paste.png")
      	     (insert "Insert from Clipbard (with shift)" "insert.png")
      	     (swap "Swap Selection with Clipboard" "swap.png"))
       (play (stop-playback "Stop Playback" "stop.png")
      	     (play "Play Track from Current Position" "play.png")
      	     (play-from-start "Play Track from Start" "play-from-start.png")
      	     (play-pattern "Play Pattern" "play-ptn.png"))
       (configure (toggle-prompt "Toggle Console" "prompt.png")
      		  (show-settings "Settings..." "settings.png")))))


  ;; ---------------------------------------------------------------------------
  ;;; ## Console
  ;; ---------------------------------------------------------------------------

  (define console
    (make <ui-repl>
      'setup (string-append "Bintracker " *bintracker-version*
			    "\n(c) 2019-2020 utz/irrlicht project\n")
      'ui-zone 'console))

  ;; ---------------------------------------------------------------------------
  ;;; ## Status Bar
  ;; ---------------------------------------------------------------------------

  ;;; Initialize the status bar at the bottom of the main window.
  (define (init-status-bar)
    (let ((status-label (status-frame 'create-widget 'label
				      textvariable: (tk-var "status-text"))))
      (reset-status-text!)
      (tk/pack status-label fill: 'x side: 'left)
      (tk/pack (status-frame 'create-widget 'sizegrip) side: 'right)))

  ;;; Set the message in the status to either a combination of the current
  ;;; module's target platform and configuration name, or the string
  ;;; "No module loaded."
  (define (reset-status-text!)
    (tk-set-var! "status-text" (string-append (get-module-info-text)
					      (state 'active-md-command-info))))

  ;;; Display `msg` in the status bar, extending the current info string.
  (define (display-action-info-status! msg)
    (tk-set-var! "status-text" (string-append (get-module-info-text)
					      msg)))

  ;;; Bind the `<Enter>`/`<Leave>` events for the given `widget` to display/
  ;;; remove the given info `text` in the status bar.
  (define (bind-info-status widget text)
    (tk/bind* widget '<Enter>
	      (lambda () (display-action-info-status! text)))
    (tk/bind* widget '<Leave> reset-status-text!))

  ;; ---------------------------------------------------------------------------
  ;;; ## Editing
  ;; ---------------------------------------------------------------------------

  ;;; #### Overview
  ;;;
  ;;; All editing of the current MDAL module is communicated through so-called
  ;;; "edit actions".
  ;;;
  ;;; An edit action is a list that takes the form
  ;;;
  ;;; `(ACTION PARENT-INSTANCE-PATH NODE-ID INSTANCES)`
  ;;;
  ;;; where ACTION is one of the symbols `set`, `insert`, or `remove`,
  ;;; PARENT-INSTANCE-PATH is a fully qualified MDAL node path string denoting
  ;;; the parent node instance of the node that you want to edit (ie. a path
  ;;; starting at the global inode, see md-types/MDMOD for details),
  ;;; NODE-ID is the ID of the node you want to edit, and INSTANCES is an
  ;;; alist where the keys are node instance ID numbers and the values are the
  ;;; values that you want to set. Values for a `remove` action are ignored, but
  ;;; you must still provide the argument as a list of lists.
  ;;;
  ;;; As the respective names suggest, a `set` action sets one or more instances
  ;;; of the node NODE-ID at PARENT-INSTANCE-PATH to (a) new value(s), an
  ;;; `insert` action inserts one or more new instances into the node, and a
  ;;; `remove` action removes one or more instances from the node.
  ;;;
  ;;; Alternatively, an edit action may take the form
  ;;;
  ;;; `(compound ACTIONS))`
  ;;;
  ;;; where ACTIONS is a list of edit actions. In this case, the edit actions
  ;;; are applied in the order provided. A `compound` action thus bundles
  ;;; one or more edit actions together.
  ;;;
  ;;; #### Applying edit actions
  ;;;
  ;;; Use the `apply-edit!` procedure to apply an edit action to the current
  ;;; module. For each edit action applied, you should push the inverse of that
  ;;; action to the undo stack. Use the `make-reverse-action` procedure to
  ;;; generate an edit action that undoes the edit action you are applying, and
  ;;; push it to the undo stack with `push-undo`. See bt-state/The Journal for
  ;;; details on Bintracker's undo/redo mechanism.

  ;;; Apply an edit action to the current module.
  (define (apply-edit! action)
    (if (eqv? 'compound (car action))
	(for-each apply-edit! (cdr action))
	((case (car action)
	   ((set) node-set!)
	   ((remove) node-remove!)
	   ((insert) node-insert!)
	   (else (warning (string-append "Unsupported edit action \""
					 (->string (car action))
					 "\""))))
	 (cadr action)
	 (third action) (fourth action) (current-mod))))

  ;;; Undo the latest edit action, by retrieving the latest action from the undo
  ;;; stack, applying it, updating the redo stack, and refreshing the display.
  (define (undo)
    (let ((action (pop-undo)))
      (when action
	(apply-edit! action)
	(blockview-update (current-order-view))
	(blockview-update (current-blocks-view))
	(switch-ui-zone-focus (state 'current-ui-zone))
	(ui-set-state (ui-ref main-toolbar 'journal) 'enabled 'redo)
	(when (zero? (app-journal-undo-stack-depth (state 'journal)))
	  (ui-set-state (ui-ref main-toolbar 'journal) 'disabled 'undo)))))

  ;;; Redo the latest undo action.
  (define (redo)
    (let ((action (pop-redo)))
      (when action
	(apply-edit! action)
	(blockview-update (current-order-view))
	(blockview-update (current-blocks-view))
	(switch-ui-zone-focus (state 'current-ui-zone))
	(ui-set-state (ui-ref main-toolbar 'journal) 'enabled 'undo)
	(when (stack-empty? (app-journal-redo-stack (state 'journal)))
	  (ui-set-state (ui-ref main-toolbar 'journal) 'disabled 'redo)))))

  ;;; Enable the undo toolbar button, and update the window title if necessary.
  (define (run-post-edit-actions)
    (ui-set-state (ui-ref main-toolbar 'journal) 'enabled 'undo)
    (unless (state 'modified)
      (set-state! 'modified #t)
      (update-window-title!)))

  ;;; Play `row` of the blocks referenced by `order-pos` in the group
  ;;; `group-id`.
  (define (play-row group-id order-pos row)
    (let ((origin (config-default-origin (current-config))))
      (emulator 'run origin
		(list->string
		 (map integer->char
		      (mod->bin (derive-single-row-mdmod
				 (current-mod) group-id order-pos row)
				origin '((no-loop #t))))))))

  ;; ---------------------------------------------------------------------------
  ;;; ## Module Display Related Widgets and Procedures
  ;; ---------------------------------------------------------------------------

  ;;; The module display is constructed as follows:
  ;;;
  ;;; Within the module display frame provided by Bintracker's top level layout,
  ;;; a `bt-group-widget` is constructed, and the GLOBAL group is associated
  ;;; with it. The `bt-group-widget` meta-widget consists of a Tk frame, which
  ;;; optionally creates a `bt-fields-widget`, a `bt-blocks-widget`, and a
  ;;; `bt-subgroups-widget` as children, for the group's fields, blocks, and
  ;;; subgroups, respectively.
  ;;;
  ;;; The `bt-fields-widget` consists of a Tk frame, which packs one or more
  ;;; `bt-field-widget` meta-widgets. A `bt-field-widget` consists of a Tk frame
  ;;; that contains a label displaying the field ID, and an input field for the
  ;;; associated value. `bt-fields-widget` and its children are only used for
  ;;; group fields, block fields are handled differently.
  ;;;
  ;;; The `bt-blocks-widget` consists of a ttk::panedwindow, containing 2 panes.
  ;;; The first pane contains the actual block display (all of the parent
  ;;; group's block members except the order block displayed next to each
  ;;; other), and the second pane contains the order or block list display.
  ;;; Both the block display and the order display are based on the `metatree`
  ;;; meta-widget, which is documented below.
  ;;;
  ;;; The `bt-subgroups-widget` consists of a Tk frame, which packs a Tk
  ;;; notebook (tab view), with tabs for each of the parent node's subgroups.
  ;;; A Tk frame is created in each of the tabs. For each subgroup, a
  ;;; `bt-group-widget` is created as a child of the corresponding tab frame.
  ;;; This allows for infinite nested groups, as required by MDAL.
  ;;;
  ;;; All `bt-*` widgets should be created by calling the corresponding
  ;;; `make-*-widget` procedures (named after the underlying `bt-*` structs, but
  ;;; dropping the `bt-*` prefix. Widgets should be packed to the display by
  ;;; calling the corresponding `show-*-widget` procedures.


  ;; ---------------------------------------------------------------------------
  ;;; ### Auxilliary procedures used by various BT meta-widgets
  ;; ---------------------------------------------------------------------------

  ;;; Determine how many characters are needed to print values of a given
  ;;; command.
  ;; TODO results should be cached
  (define (value-display-size command-config)
    (case (command-type command-config)
      ;; FIXME this is incorrect for negative numbers
      ((int uint) (inexact->exact
		   (ceiling
		    (/ (log (expt 2 (command-bits command-config)))
		       (log (settings 'number-base))))))
      ((key ukey) (if (memq 'is-note (command-flags command-config))
		      3 (apply max
			       (map (o string-length car)
				    (hash-table-keys
				     (command-keys command-config))))))
      ((reference) (if (>= 16 (settings 'number-base))
		       2 3))
      ((trigger) 1)
      ((string) 32)))

  ;;; Transform an ifield value from MDAL format to tracker display format.
  ;;; Replaces empty values with dots, changes numbers depending on number
  ;;; format setting, and turns everything into a string.
  (define (normalize-field-value val field-id)
    (let* ((command-config (config-get-inode-source-command
  			    field-id (current-config)))
	   (display-size (value-display-size command-config)))
      (cond ((not val) (list->string (make-list display-size #\.)))
	    ((null? val) (list->string (make-list display-size #\space)))
	    (else (case (command-type command-config)
		    ((int uint reference)
		     (string-pad (number->string val (settings 'number-base))
				 display-size #\0))
		    ((key ukey) (if (memq 'is-note
					  (command-flags command-config))
				    (normalize-note-name val)
				    val))
		    ((trigger) "x")
		    ((string) val))))))

  ;;; Get the color tag asscociated with the field's command type.
  (define (get-field-color-tag field-id)
    (let ((command-config (config-get-inode-source-command
			   field-id (current-config))))
      (if (memq 'is-note (command-flags command-config))
	  'text-1
	  (case (command-type command-config)
	    ((int uint) 'text-2)
	    ((key ukey) 'text-3)
	    ((reference) 'text-4)
	    ((trigger) 'text-5)
	    ((string) 'text-6)
	    ((modifier) 'text-7)
	    (else 'text)))))

  ;;; Get the RGB color string associated with the field's command type.
  (define (get-field-color field-id)
    (colors (get-field-color-tag field-id)))

  ;;; Convert a keysym (as returned by a tk-event `%K` placeholder) to an
  ;;; MDAL note name.
  (define (keypress->note key)
    (let ((entry-spec (alist-ref (string->symbol
				  (string-append "<Key-" (->string key)
						 ">"))
				 (app-keys-note-entry (settings 'keymap)))))
      (and entry-spec
	   (if (string= "rest" (car entry-spec))
	       'rest
	       (let* ((octave-modifier (if (> (length entry-spec) 1)
					   (cadr entry-spec)
					   0))
		      (mod-octave (+ octave-modifier (state 'base-octave))))
		 ;; TODO proper range check
		 (and (and (>= mod-octave 0)
			   (<= mod-octave 9)
			   (string->symbol
			    (string-append (car entry-spec)
					   (->string mod-octave))))))))))

  ;;; Get the appropriate command type tag to set the item color.
  (define (get-command-type-tag field-id)
    (let ((command-config (config-get-inode-source-command
			   field-id (current-config))))
      (if (memq 'is-note (command-flags command-config))
	  'note
	  (case (command-type command-config)
	    ((int uint) 'int)
	    ((key ukey) 'key)
	    (else (command-type command-config))))))


  ;;; Generate an abbrevation of `len` characters from the given MDAL inode
  ;;; identifier `id`. Returns the abbrevation as a string. The string is
  ;;; padded to `len` characters if necessary.
  (define (node-id-abbreviate id len)
    (let ((chars (string->list (symbol->string id))))
      (if (>= len (length chars))
	  (string-pad-right (list->string chars)
			    len)
	  (case len
	    ((1) (->string (car chars)))
	    ((2) (list->string (list (car chars) (car (reverse chars)))))
	    (else (list->string (append (take chars (- len 2))
					(list #\. (car (reverse chars))))))))))


  ;; ---------------------------------------------------------------------------
  ;;; ### Field-Related Widgets and Procedures
  ;; ---------------------------------------------------------------------------

  ;;; A meta widget for displaying an MDAL group field.
  (defstruct bt-field-widget
    (toplevel-frame : procedure)
    (id-label : procedure)
    (val-entry : procedure)
    (node-id : symbol))

  ;;; Create a `bt-field-widget`.
  (define (make-field-widget node-id parent-widget)
    (let ((tl-frame (parent-widget 'create-widget 'frame style: 'BT.TFrame))
	  (color (get-field-color node-id)))
      (make-bt-field-widget
       toplevel-frame: tl-frame
       node-id: node-id
       id-label: (tl-frame 'create-widget 'label style: 'BT.TLabel
			   foreground: color text: (symbol->string node-id))
       val-entry: (tl-frame 'create-widget 'entry
			    bg: (colors 'row-highlight-minor) fg: color
			    bd: 0 highlightthickness: 0 insertborderwidth: 1
			    justify: 'center
			    font: (list family: (settings 'font-mono)
					size: (settings 'font-size)
					weight: 'bold)))))

  ;;; Display a `bt-field-widget`.
  (define (show-field-widget w group-instance-path)
    (tk/pack (bt-field-widget-toplevel-frame w)
	     side: 'left)
    (tk/pack (bt-field-widget-id-label w)
	     (bt-field-widget-val-entry w)
	     side: 'top padx: 4 pady: 4)
    ((bt-field-widget-val-entry w) 'insert 'end
     (normalize-field-value (cddr
    			     ((node-path
    			       (string-append
    				group-instance-path
    				(symbol->string (bt-field-widget-node-id w))
    				"/0/"))
    			      (mdmod-global-node (current-mod))))
    			    (bt-field-widget-node-id w))))

  (define (focus-field-widget w)
    (let ((entry (bt-field-widget-val-entry w)))
      (entry 'configure bg: (colors 'cursor))
      (tk/focus entry)))

  (define (unfocus-field-widget w)
    ((bt-field-widget-val-entry w) 'configure
     bg: (colors 'row-highlight-minor)))

  ;;; A meta widget for displaying an MDAL group's field members.
  (defstruct bt-fields-widget
    (toplevel-frame : procedure)
    (parent-node-id : symbol)
    ((fields '()) : (list-of (struct bt-field-widget)))
    ((active-index 0) : fixnum))

  ;;; Create a `bt-fields-widget`.
  (define (make-fields-widget parent-node-id parent-widget)
    (let ((subnode-ids (config-get-subnode-type-ids parent-node-id
						    (current-config)
						    'field)))
      (if (null? subnode-ids)
	  #f
	  (let ((tl-frame (parent-widget 'create-widget 'frame
					 style: 'BT.TFrame)))
	    (make-bt-fields-widget
	     toplevel-frame: tl-frame
	     parent-node-id: parent-node-id
	     fields: (map (cute make-field-widget <> tl-frame)
			  subnode-ids))))))

  ;;; Show a group fields widget.
  (define (show-fields-widget w group-instance-path)
    (begin
      (tk/pack (bt-fields-widget-toplevel-frame w)
	       fill: 'x)
      (for-each (lambda (field-widget index)
		  (let ((bind-tk-widget-button-press
			 (lambda (widget)
			   (tk/bind* widget '<ButtonPress-1>
				     (lambda ()
				       (unfocus-field-widget
					(list-ref (bt-fields-widget-fields w)
						  (bt-fields-widget-active-index
						   w)))
				       (bt-fields-widget-active-index-set!
					w index)
				       (switch-ui-zone-focus 'fields)))))
			(val-entry (bt-field-widget-val-entry field-widget)))
		    (show-field-widget field-widget group-instance-path)
		    (tk/bind* val-entry '<Tab> (lambda ()
						 (select-next-field w)))
		    (reverse-binding-eval-order val-entry)
		    (bind-tk-widget-button-press val-entry)
		    (bind-tk-widget-button-press
		     (bt-field-widget-id-label field-widget))
		    (bind-tk-widget-button-press
		     (bt-field-widget-toplevel-frame field-widget))))
		(bt-fields-widget-fields w)
		(iota (length (bt-fields-widget-fields w))))
      (tk/bind* (bt-fields-widget-toplevel-frame w)
		'<ButtonPress-1> (lambda ()
				   (switch-ui-zone-focus 'fields)))))

  (define (focus-fields-widget w)
    (focus-field-widget (list-ref (bt-fields-widget-fields w)
				  (bt-fields-widget-active-index w))))

  (define (unfocus-fields-widget w)
    (unfocus-field-widget (list-ref (bt-fields-widget-fields w)
				    (bt-fields-widget-active-index w))))

  (define (select-next-field fields-widget)
    (let ((current-index (bt-fields-widget-active-index fields-widget)))
      (unfocus-fields-widget fields-widget)
      (bt-fields-widget-active-index-set!
       fields-widget
       (if (< current-index (sub1 (length (bt-fields-widget-fields
					   fields-widget))))
	   (add1 current-index)
	   0))
      (focus-fields-widget fields-widget)))


  ;; ---------------------------------------------------------------------------
  ;;; ### TextGrid
  ;; ---------------------------------------------------------------------------

  ;;; TextGrids are Tk Text widgets with default bindings removed and/or
  ;;; replaced with Bintracker-specific bindings. TextGrids form the basis of
  ;;; Bintrackers blockview metawidget, which is used to display sets of blocks
  ;;; or order lists. A number of abstractions are provided to facilitate this.

  ;;; Configure TextGrid widget tags.
  (define (textgrid-configure-tags tg)
    (tg 'tag 'configure 'rowhl-minor background: (colors 'row-highlight-minor))
    (tg 'tag 'configure 'rowhl-major background: (colors 'row-highlight-major))
    (tg 'tag 'configure 'active-cell background: (colors 'cursor))
    (tg 'tag 'configure 'txt foreground: (colors 'text))
    (tg 'tag 'configure 'note foreground: (colors 'text-1))
    (tg 'tag 'configure 'int foreground: (colors 'text-2))
    (tg 'tag 'configure 'key foreground: (colors 'text-3))
    (tg 'tag 'configure 'reference foreground: (colors 'text-4))
    (tg 'tag 'configure 'trigger foreground: (colors 'text-5))
    (tg 'tag 'configure 'string foreground: (colors 'text-6))
    (tg 'tag 'configure 'modifier foreground: (colors 'text-7))
    (tg 'tag 'configure 'active font: (list (settings 'font-mono)
  					     (settings 'font-size)
  					     "bold")))

  ;;; Abstraction over Tk's `textwidget tag add` command.
  ;;; Contrary to Tk's convention, `row` uses 0-based indexing.
  ;;; `tags` may be a single tag, or a list of tags.
  (define (textgrid-do-tags method tg tags first-row #!optional
			    (first-col 0) (last-col 'end) (last-row #f))
    (for-each (lambda (tag)
		(tg 'tag method tag
		    (string-append (->string (+ 1 first-row))
				   "." (->string first-col))
		    (string-append (->string (+ 1 (or last-row first-row)))
				   "." (->string last-col))))
	      (if (pair? tags)
		  tags (list tags))))

  (define (textgrid-add-tags . args)
    (apply textgrid-do-tags (cons 'add args)))

  (define (textgrid-remove-tags . args)
    (apply textgrid-do-tags (cons 'remove args)))

  (define (textgrid-remove-tags-globally tg tags)
    (for-each (cute tg 'tag 'remove <> "0.0" "end")
	      tags))

  ;;; Convert the `row`, `char` arguments into a Tk Text index string.
  ;;; `row` is adjusted from 0-based indexing to 1-based indexing.
  (define (textgrid-position->tk-index row char)
    (string-append (->string (add1 row))
		   "." (->string char)))

  ;;; Create a TextGrid as slave of the Tk widget `parent`. Returns a Tk Text
  ;;; widget with class bindings removed.
  (define (textgrid-create-basic parent)
    (let* ((tg (parent 'create-widget 'text bd: 0 highlightthickness: 0
		       selectborderwidth: 0 padx: 0 pady: 4
		       bg: (colors 'background)
		       fg: (colors 'text-inactive)
		       insertbackground: (colors 'text)
		       insertontime: 0 spacing3: (settings 'line-spacing)
		       font: (list family: (settings 'font-mono)
				   size: (settings 'font-size))
		       cursor: '"" undo: 0 wrap: 'none))
	   (id (tg 'get-id)))
      (tk-eval (string-append "bindtags " id " {all . " id "}"))
      (textgrid-configure-tags tg)
      tg))

  (define (textgrid-create parent)
    (textgrid-create-basic parent))


  ;; ---------------------------------------------------------------------------
  ;;; ## BlockView
  ;; ---------------------------------------------------------------------------

  ;;; The BlockView metawidget is a generic widget that implements a spreadsheet
  ;;; display. In Bintracker, it is used to display both MDAL blocks (patterns,
  ;;; tables, etc.) and the corresponding order or list view.

  (defstruct bv-field-config
    (type-tag : symbol)
    (width : fixnum)
    (start : fixnum)
    (cursor-width : fixnum)
    (cursor-digits : fixnum))

  (defstruct blockview
    (type : symbol)
    (group-id : symbol)
    (block-ids : (list-of symbol))
    (field-ids : (list-of symbol))
    (field-configs : list)
    (header-frame : procedure)
    (packframe : procedure)
    (rownum-frame : procedure)
    (rownum-header : procedure)
    (rownums : procedure)
    (content-frame : procedure)
    (content-header : procedure)
    (content-grid : procedure)
    (xscroll : procedure)
    (yscroll : procedure)
    ((item-cache '()) : list))

  ;;; Returns the number of characters that the blockview cursor should span
  ;;; for the given `field-id`.
  (define (field-id->cursor-size field-id)
    (let ((cmd-config (config-get-inode-source-command field-id
						       (current-config))))
      (if (memq 'is-note (command-flags cmd-config))
	  3
	  (if (memq (command-type cmd-config)
		    '(key ukey))
	      (value-display-size cmd-config)
	      1))))

  ;;; Returns the number of cursor positions for the the field node
  ;;; `field-id`. For fields that are based on note/key/ukey commands, the
  ;;; result will be one, otherwise it will be equal to the number of characters
  ;;; needed to represent the valid input range for the field's source command.
  (define (field-id->cursor-digits field-id)
    (let ((cmd-config (config-get-inode-source-command field-id
						       (current-config))))
      (if (memq (command-type cmd-config)
		'(key ukey))
	  1 (value-display-size cmd-config))))

  ;;; Generic procedure for mapping tags to the field columns of a textgrid.
  ;;; This can be used either on the content header, or on the content grid.
  (define (blockview-add-column-tags b textgrid row taglist)
    (for-each (lambda (tag field-config)
		(let ((start (bv-field-config-start field-config)))
		  (textgrid-add-tags textgrid tag row start
				     (+ start
					(bv-field-config-width field-config)))))
	      taglist
	      (map cadr (blockview-field-configs b))))

  ;;; Add type tags to the given row in `textgrid`. If `textgrid` is not
  ;;; given, it defaults to the blockview's content-grid.
  (define (blockview-add-type-tags b row #!optional
				   (textgrid (blockview-content-grid b)))
    (blockview-add-column-tags b textgrid row
			       (map (o bv-field-config-type-tag cadr)
				    (blockview-field-configs b))))

  ;;; Generate the alist of bv-field-configs.
  (define (blockview-make-field-configs block-ids field-ids)
    (letrec* ((type-tags (map get-command-type-tag field-ids))
	      (sizes (map (lambda (id)
	      		    (value-display-size (config-get-inode-source-command
	      					 id (current-config))))
	      		  field-ids))
	      (cursor-widths (map field-id->cursor-size field-ids))
	      (cursor-ds (map field-id->cursor-digits field-ids))
	      (tail-fields
	       (map (lambda (id)
	      	      (car (reverse (config-get-subnode-ids
				     id (config-itree (current-config))))))
	      	    (drop-right block-ids 1)))
	      (convert-sizes
	       (lambda (sizes start)
		 (if (null-list? sizes)
		     '()
		     (cons start
			   (convert-sizes (cdr sizes)
					  (+ start (car sizes)))))))
	      (start-positions (convert-sizes
	      			(map (lambda (id size)
	      			       (if (memq id tail-fields)
	      				   (+ size 2)
	      				   (+ size 1)))
	      			     field-ids sizes)
	      			0)))
      (map (lambda (field-id type-tag size start c-width c-digits)
	     (list field-id (make-bv-field-config type-tag: type-tag
						  width: size start: start
						  cursor-width: c-width
						  cursor-digits: c-digits)))
	   field-ids type-tags sizes start-positions cursor-widths
	   cursor-ds)))

  ;;; Returns a blockview metawidget that is suitable for the MDAL group
  ;;; `group-id`. `type` must be `'block` for a regular blockview showing
  ;;; the group's block node members, or '`order` for a blockview showing the
  ;;; group's order list.
  (define (blockview-create parent type group-id)
    (let* ((header-frame (parent 'create-widget 'frame))
	   (packframe (parent 'create-widget 'frame))
  	   (rownum-frame (packframe 'create-widget 'frame style: 'BT.TFrame))
	   (content-frame (packframe 'create-widget 'frame))
  	   (block-ids
  	    (and (eq? type 'block)
  		 (remove (cute eq? <> (symbol-append group-id '_ORDER))
  			 (config-get-subnode-type-ids group-id (current-config)
  						      'block))))
  	   (field-ids (if (eq? type 'block)
  			  (flatten (map (cute config-get-subnode-ids <>
					      (config-itree (current-config)))
					block-ids))
  			  (config-get-subnode-ids
  			   (symbol-append group-id '_ORDER)
  			   (config-itree (current-config)))))
	   (rownums (textgrid-create-basic rownum-frame))
	   (grid (textgrid-create content-frame)))
      (make-blockview
       type: type group-id: group-id block-ids: block-ids field-ids: field-ids
       field-configs: (blockview-make-field-configs
		       (or block-ids (list (symbol-append group-id '_ORDER)))
       		       field-ids)
       header-frame: header-frame packframe: packframe
       rownum-frame: rownum-frame content-frame: content-frame
       rownum-header: (textgrid-create-basic rownum-frame)
       rownums: rownums
       content-header: (textgrid-create-basic content-frame)
       content-grid: grid
       xscroll: (parent 'create-widget 'scrollbar orient: 'horizontal
  			command: `(,grid xview))
       yscroll: (packframe 'create-widget 'scrollbar orient: 'vertical
			   command: (lambda args
				      (apply grid (cons 'yview args))
				      (apply rownums (cons 'yview args)))))))

  ;;; Convert the list of row `values` into a string that can be inserted into
  ;;; the blockview's content-grid or header-grid. Each entry in `values` must
  ;;; correspond to a field column in the blockview's content-grid.
  (define (blockview-values->row-string b values)
    (letrec ((construct-string
	      (lambda (str vals configs)
		(if (null-list? vals)
		    str
		    (let ((next-chunk
			   (string-append
			    str
			    (list->string
			     (make-list (- (bv-field-config-start (car configs))
					   (string-length str))
					#\space))
			    (->string (car vals)))))
		      (construct-string next-chunk (cdr vals)
					(cdr configs)))))))
      (construct-string "" values (map cadr (blockview-field-configs b)))))

  ;;; Set up the column and block header display.
  (define (blockview-init-content-header b)
    (let* ((header (blockview-content-header b))
  	   (block? (eq? 'block (blockview-type b)))
  	   (field-ids (blockview-field-ids b)))
      (when block?
  	(header 'insert 'end
		(string-append/shared
		 (string-intersperse
		  (map (lambda (id)
			 (node-id-abbreviate
			  id
			  (apply + (map (o add1 bv-field-config-width cadr)
					(filter
					 (lambda (field-config)
					   (memq (car field-config)
						 (config-get-subnode-ids
						  id (config-itree
						      (current-config)))))
					 (blockview-field-configs b))))))
		       (blockview-block-ids b)))
  		 "\n"))
  	(textgrid-add-tags header '(active txt) 0))
      (header 'insert 'end
	      (blockview-values->row-string
	       b (map node-id-abbreviate
		      (if block?
			  field-ids
			  (cons 'ROWS
				(map (lambda (id)
				       (string->symbol
					(string-drop (symbol->string id) 2)))
				     (cdr field-ids))))
		      (map (o bv-field-config-width cadr)
			   (blockview-field-configs b)))))
      (textgrid-add-tags header 'active (if block? 1 0))
      (blockview-add-type-tags b (if block? 1 0)
      			       (blockview-content-header b))))

  ;;; Returns the position of `mark` as a list containing the row in car,
  ;;; and the character position in cadr. Row position is adjusted to 0-based
  ;;; indexing.
  (define (blockview-mark->position b mark)
    (let ((pos (map string->number
		    (string-split ((blockview-content-grid b) 'index mark)
				  "."))))
      (list (sub1 (car pos))
	    (cadr pos))))

  ;;; Returns the current cursor position as a list containing the row in car,
  ;;; and the character position in cadr. Row position is adjusted to 0-based
  ;;; indexing.
  (define (blockview-get-cursor-position b)
    (blockview-mark->position b 'insert))

  ;;; Returns the current row, ie. the row that the cursor is currently on.
  (define (blockview-get-current-row b)
    (car (blockview-get-cursor-position b)))

  ;;; Returns the field ID that the cursor is currently on.
  (define (blockview-get-current-field-id b)
    (let ((char-pos (cadr (blockview-get-cursor-position b))))
      (list-ref (blockview-field-ids b)
		(list-index
		 (lambda (cfg)
		   (and (>= char-pos (bv-field-config-start (cadr cfg)))
			(> (+ (bv-field-config-start (cadr cfg))
			      (bv-field-config-width (cadr cfg)))
			   char-pos)))
		 (blockview-field-configs b)))))

  ;;; Returns the ID of the parent block node if the field that the cursor is
  ;;; currently on.
  (define (blockview-get-current-block-id b)
    (config-get-parent-node-id (blockview-get-current-field-id b)
			       (config-itree (current-config))))

  ;;; Returns the bv-field-configuration for the field that the cursor is
  ;;; currently on.
  (define (blockview-get-current-field-config b)
    (car (alist-ref (blockview-get-current-field-id b)
		    (blockview-field-configs b))))

  ;;; Returns the MDAL command config for the field that the cursor is
  ;;; currently on.
  (define (blockview-get-current-field-command b)
    (config-get-inode-source-command (blockview-get-current-field-id b)
				     (current-config)))

  ;;; Returns the corresponding group order position for the chunk currently
  ;;; under cursor. For order type blockviews, the result is equal to the
  ;;; current row.
  (define (blockview-get-current-order-pos b)
    (let ((current-row (blockview-get-current-row b)))
      (if (eq? 'order (blockview-type b))
	  current-row
	  (list-index (lambda (start+end)
			(and (>= current-row (car start+end))
			     (<= current-row (cadr start+end))))
		      (blockview-start+end-positions b)))))

  ;;; Returns the chunk from the item cache that the cursor is currently on.
  (define (blockview-get-current-chunk b)
    (list-ref (blockview-item-cache b)
	      (blockview-get-current-order-pos b)))

  ;;; Update the command information in the status bar, based on the field that
  ;;; the cursor currently points to.
  (define (blockview-update-current-command-info b)
    (let ((current-field-id (blockview-get-current-field-id b)))
      (if (eq? 'order (blockview-type b))
	  (set-state! 'active-md-command-info
		      (if (symbol-contains current-field-id "_LENGTH")
			  "Step Length"
			  (string-append "Channel "
					 (string-drop (symbol->string
						       current-field-id)
						      2))))
	  (set-active-md-command-info! current-field-id))
      (reset-status-text!)))

  ;;; Get the up-to-date list of items to display. The list is nested. The first
  ;;; nesting level corresponds to an order position. The second nesting level
  ;;; corresponds to a row of fields. For order nodes, there is only one element
  ;;; at the first nesting level.
  (define (blockview-get-item-list b)
    (let* ((group-id (blockview-group-id b))
  	   (group-instance (get-current-node-instance group-id))
  	   (order (mod-get-order-values group-id group-instance)))
      (if (eq? 'order (blockview-type b))
  	  (list order)
	  (map (lambda (order-pos)
		 (let ((block-values (mod-get-block-values group-instance
							   (cdr order-pos)))
		       (chunk-length (car order-pos)))
		   (if (<= chunk-length (length block-values))
		       (take block-values chunk-length)
		       (append block-values
			       (make-list (- chunk-length (length block-values))
					  (make-list (length (car block-values))
						     '()))))))
	       order))))

  ;;; Determine the start and end positions of each item chunk in the
  ;;; blockview's item cache.
  (define (blockview-start+end-positions b)
    (letrec* ((get-positions
  	       (lambda (current-pos items)
  		 (if (null-list? items)
  		     '()
  		     (let ((len (length (car items))))
  		       (cons (list current-pos (+ current-pos (sub1 len)))
  			     (get-positions (+ current-pos len)
  					    (cdr items))))))))
      (get-positions 0 (blockview-item-cache b))))

  ;;; Get the total number of rows of the blockview's contents.
  (define (blockview-get-total-length b)
    (apply + (map length (blockview-item-cache b))))

  ;;; Returns the active blockview zone as a list containing the first and last
  ;;; row in car and cadr, respectively.
  (define (blockview-get-active-zone b)
    (let ((start+end-positions (blockview-start+end-positions b))
	  (current-row (blockview-get-current-row b)))
      (list-ref start+end-positions
		(list-index (lambda (start+end)
			      (and (>= current-row (car start+end))
				   (<= current-row (cadr start+end))))
			    start+end-positions))))

  ;;; Return the field instance ID currently under cursor.
  (define (blockview-get-current-field-instance b)
    (- (blockview-get-current-row b)
       (car (blockview-get-active-zone b))))

  ;;; Return the block instance ID currently under cursor.
  (define (blockview-get-current-block-instance b)
    (let ((current-block-id (blockview-get-current-block-id b)))
      (list-ref (list-ref (map cdr
			       (mod-get-order-values
				(blockview-group-id b)
				(get-current-node-instance
				 (blockview-group-id b))))
			  (blockview-get-current-order-pos b))
		(list-index (lambda (block-id)
			      (eq? block-id current-block-id))
			    (blockview-block-ids b)))))

  ;;; Return the MDAL node path string of the field currently under cursor.
  (define (blockview-get-current-block-instance-path b)
    (string-append (get-current-instance-path (blockview-group-id b))
		   (symbol->string (blockview-get-current-block-id b))
		   "/" (->string (blockview-get-current-block-instance b))))

  ;;; Return the index of the the current field node ID in the blockview's list
  ;;; of field IDs. The result can be used to retrieve a field instance value
  ;;; from a chunk in the item cache.
  (define (blockview-get-current-field-index b)
    (list-index (lambda (id)
		  (eq? id (blockview-get-current-field-id b)))
		(blockview-field-ids b)))

  ;;; Returns the (un-normalized) value of the field instance currently under
  ;;; cursor.
  (define (blockview-get-current-field-value b)
    (list-ref (list-ref (blockview-get-current-chunk b)
			(blockview-get-current-field-instance b))
	      (blockview-get-current-field-index b)))

  ;;; Apply type tags and the 'active tag to the current active zone of the
  ;;; blockview `b`.
  (define (blockview-tag-active-zone b)
    (let ((zone-limits (blockview-get-active-zone b))
	  (grid (blockview-content-grid b))
	  (rownums (blockview-rownums b)))
      (textgrid-remove-tags-globally
       grid (cons 'active (map (o bv-field-config-type-tag cadr)
			       (blockview-field-configs b))))
      (textgrid-remove-tags-globally rownums '(active txt))
      (textgrid-add-tags rownums '(active txt)
			 (car zone-limits)
			 0 'end (cadr zone-limits))
      (textgrid-add-tags grid 'active (car zone-limits)
			 0 'end (cadr zone-limits))
      (for-each (lambda (row)
		  (blockview-add-type-tags b row))
		(iota (- (cadr zone-limits)
			 (sub1 (car zone-limits)))
		      (car zone-limits) 1))))

  ;;; Update the row highlights of the blockview.
  (define (blockview-update-row-highlights b)
    (let* ((start-positions (map car (blockview-start+end-positions b)))
	   (minor-hl (state 'minor-row-highlight))
	   (major-hl (* minor-hl (state 'major-row-highlight)))
	   (make-rowlist
	    (lambda (hl-distance)
	      (flatten
	       (map (lambda (chunk start)
		      (map (cute + <> start)
			   (filter (lambda (i)
				     (zero? (modulo i hl-distance)))
				   (iota (length chunk)))))
		    (blockview-item-cache b)
		    start-positions))))
	   (rownums (blockview-rownums b))
	   (content (blockview-content-grid b)))
      (for-each (lambda (row)
      		  (textgrid-add-tags rownums 'rowhl-minor row)
      		  (textgrid-add-tags content 'rowhl-minor row))
      		(make-rowlist minor-hl))
      (for-each (lambda (row)
		  (textgrid-add-tags rownums 'rowhl-major row)
		  (textgrid-add-tags content 'rowhl-major row))
		(make-rowlist major-hl))))

  ;;; Update the blockview row numbers according to the current item cache.
  (define (blockview-update-row-numbers b)
    (let ((padding (if (eq? 'block (blockview-type b))
		       4 3)))
      ((blockview-rownums b) 'replace "0.0" 'end
       (string-intersperse
	(flatten
	 (map (lambda (chunk)
		(map (lambda (i)
		       (string-pad-right
			(string-pad (number->string i (settings 'number-base))
				    padding #\0)
			(+ 2 padding)))
		     (iota (length chunk))))
	      (blockview-item-cache b)))
	"\n"))))

  ;;; Perform a full update of the blockview content grid.
  (define (blockview-update-content-grid b)
    ((blockview-content-grid b) 'replace "0.0" 'end
     (string-intersperse (map (lambda (row)
				(blockview-values->row-string
				 b
				 (map (lambda (val id)
					(normalize-field-value val id))
				      row (blockview-field-ids b))))
			      (concatenate (blockview-item-cache b)))
			 "\n")))

  ;;; Update the blockview content grid on a row by row basis. This compares
  ;;; the `new-item-list` against the current item cache, and only updates
  ;;; rows that have changed. The list length of `new-item-list` and the
  ;;; lengths of each of the subchunks must match the list of items in the
  ;;; current item cache.
  ;;; This operation does not update the blockview's item cache, which should
  ;;; be done manually after calling this procedure.
  (define (blockview-update-content-rows b new-item-list)
    (let ((grid (blockview-content-grid b)))
      (for-each (lambda (old-row new-row row-pos)
		  (unless (equal? old-row new-row)
		    (let* ((start (textgrid-position->tk-index row-pos 0))
			   (end (textgrid-position->tk-index row-pos 'end))
			   (tags (map string->symbol
				      (string-split (grid 'tag 'names start))))
			   (active-zone? (memq 'active tags))
			   (major-hl? (memq 'rowhl-major tags))
			   (minor-hl? (memq 'rowhl-minor tags)))
		      (grid 'replace start end
			    (blockview-values->row-string
			     b (map (lambda (val id)
				      (normalize-field-value val id))
				    new-row (blockview-field-ids b))))
		      (when major-hl?
			(grid 'tag 'add 'rowhl-major start end))
		      (when minor-hl?
			(grid 'tag 'add 'rowhl-minor start end))
		      (when active-zone?
			(blockview-add-type-tags b row-pos)))))
		(concatenate (blockview-item-cache b))
		(concatenate new-item-list)
		(iota (length (concatenate new-item-list))))))

  ;;; Returns a list of character positions that the blockview's cursor may
  ;;; assume.
  (define (blockview-cursor-x-positions b)
    (flatten (map (lambda (field-cfg)
		    (map (cute + <> (bv-field-config-start field-cfg))
			 (iota (bv-field-config-cursor-digits field-cfg))))
		  (map cadr (blockview-field-configs b)))))

  ;;; Show or hide the blockview's cursor. `action` shall be `'add` or
  ;;; `'remove`.
  (define (blockview-cursor-do b action)
    ((blockview-content-grid b) 'tag action 'active-cell "insert"
     (string-append "insert +"
		    (->string (bv-field-config-cursor-width
			       (blockview-get-current-field-config b)))
		    "c")))

  ;;; Hide the blockview's cursor.
  (define (blockview-remove-cursor b)
    (blockview-cursor-do b 'remove))

  ;;; Show the blockview's cursor.
  (define (blockview-show-cursor b)
    (blockview-cursor-do b 'add))

  ;;; Set the cursor to the given coordinates.
  (define (blockview-set-cursor b row char)
    (let ((grid (blockview-content-grid b))
	  (active-zone (blockview-get-active-zone b)))
      (blockview-remove-cursor b)
      (grid 'mark 'set 'insert (textgrid-position->tk-index row char))
      (when (or (< row (car active-zone))
		(> row (cadr active-zone)))
	(blockview-tag-active-zone b))
      (blockview-show-cursor b)
      (grid 'see 'insert)
      ((blockview-rownums b) 'see (textgrid-position->tk-index row 0))))

  ;;; Set the blockview's cursor to the grid position currently closest to the
  ;;; mouse pointer.
  (define (blockview-set-cursor-from-mouse b)
    (let ((mouse-pos (blockview-mark->position b 'current))
	  (ui-zone-id (if (eq? 'block (blockview-type b))
			       'blocks 'order)))
      (unless (eq? ui-zone-id
		   (car (list-ref ui-zones (state 'current-ui-zone))))
	(switch-ui-zone-focus ui-zone-id))
      (blockview-set-cursor b (car mouse-pos)
			    (find (cute <= <> (cadr mouse-pos))
				  (reverse (blockview-cursor-x-positions b))))
      (blockview-update-current-command-info b)))

  ;;; Move the blockview's cursor in `direction`.
  (define (blockview-move-cursor b direction)
    (let* ((grid (blockview-content-grid b))
	   (current-pos (blockview-get-cursor-position b))
	   (current-row (car current-pos))
	   (current-char (cadr current-pos))
	   (total-length (blockview-get-total-length b))
	   (step (if (eq? 'order (blockview-type b))
		     1
		     (if (zero? (state 'edit-step))
			 1 (state 'edit-step)))))
      (blockview-set-cursor
       b
       (case direction
	 ((Up) (if (zero? current-row)
		   (sub1 total-length)
		   (sub1 current-row)))
	 ((Down) (if (>= (+ step current-row) total-length)
		     0 (+ step current-row)))
	 ((Home) (if (zero? current-row)
		     current-row
		     (car (find (lambda (start+end)
				  (< (car start+end)
				     current-row))
				(reverse (blockview-start+end-positions b))))))
	 ((End) (if (= current-row (sub1 total-length))
		    current-row
		    (let ((next-pos (find (lambda (start+end)
					    (> (car start+end)
					       current-row))
					  (blockview-start+end-positions b))))
		      (if next-pos
			  (car next-pos)
			  (sub1 total-length)))))
	 (else current-row))
       (case direction
	 ((Left) (or (find (cute < <> current-char)
			   (reverse (blockview-cursor-x-positions b)))
		     (car (reverse (blockview-cursor-x-positions b)))))
	 ((Right) (or (find (cute > <> current-char)
			    (blockview-cursor-x-positions b))
		      0))
	 (else current-char)))
      (when (memv direction '(Left Right))
	(blockview-update-current-command-info b))))

  ;;; Set the input focus to the blockview `b`. In addition to setting the
  ;;; Tk focus, it also shows the cursor and updates the status bar info text.
  (define (blockview-focus b)
    (blockview-show-cursor b)
    (tk/focus (blockview-content-grid b))
    (blockview-update-current-command-info b))

  ;;; Unset focus from the blockview `b`.
  (define (blockview-unfocus b)
    (blockview-remove-cursor b)
    (set-state! 'active-md-command-info "")
    (reset-status-text!))

  ;;; Delete the field node instance that corresponds to the current cursor
  ;;; position, and insert an empty node at the end of the block instead.
  (define (blockview-cut-current-cell b)
    (unless (null? (blockview-get-current-field-value b))
      (let ((action (list 'remove
			  (blockview-get-current-block-instance-path b)
			  (blockview-get-current-field-id b)
			  `((,(blockview-get-current-field-instance b))))))
	(push-undo (make-reverse-action action))
	(apply-edit! action)
	(blockview-update b)
	(blockview-move-cursor b 'Up)
	(run-post-edit-actions))))

  ;;; Insert an empty cell into the field column currently under cursor,
  ;;; shifting the following node instances down and dropping the last instance.
  (define (blockview-insert-cell b)
    (unless (null? (blockview-get-current-field-value b))
      (let ((action (list 'insert
			   (blockview-get-current-block-instance-path b)
			   (blockview-get-current-field-id b)
			   `((,(blockview-get-current-field-instance b)
			      ())))))
	(push-undo (make-reverse-action action))
	(apply-edit! action)
	(blockview-update b)
	(blockview-show-cursor b)
	(run-post-edit-actions))))

  ;;; Set the field node instance that corresponds to the current cursor
  ;;; position to `new-value`, and update the display and the undo/redo stacks
  ;;; accordingly.
  (define (blockview-edit-current-cell b new-value)
    (let ((action `(set ,(blockview-get-current-block-instance-path b)
			,(blockview-get-current-field-id b)
			((,(blockview-get-current-field-instance b)
			  ,new-value)))))
      (push-undo (make-reverse-action action))
      (apply-edit! action)
      ;; TODO might want to make this behaviour user-configurable
      (when (eqv? 'block (blockview-type b))
	(play-row (blockview-group-id b)
		  (blockview-get-current-order-pos b)
		  (blockview-get-current-field-instance b)))
      (blockview-update b)
      (unless (zero? (state 'edit-step))
	(blockview-move-cursor b 'Down))
      (run-post-edit-actions)))

  ;;; Perform an edit action at cursor, assuming that the cursor points to a
  ;;; field that represents a note command.
  (define (blockview-enter-note b keysym)
    (let ((note-val (keypress->note keysym)))
      (when note-val
	(blockview-edit-current-cell b note-val))))

  ;;; Perform an edit action at cursor, assuming that the cursor points to a
  ;;; field that represents a note command.
  (define (blockview-enter-trigger b)
    (blockview-edit-current-cell b #t))

  ;;; Perform an edit action at cursor, assuming that the cursor points to a
  ;;; field that represents a key/ukey command.
  (define (blockview-enter-key b keysym)
    (display "key entry")
    (newline))

  ;;; Perform an edit action at cursor, assuming that the cursor points to a
  ;;; field that represents a numeric (int/uint) command.
  (define (blockview-enter-numeric b keysym)
    (display "numeric entry")
    (newline))

  ;;; Perform an edit action at cursor, assuming that the cursor points to a
  ;;; field that represents a reference command.
  (define (blockview-enter-reference b keysym)
    (display "reference entry")
    (newline))

  ;;; Perform an edit action at cursor, assuming that the cursor points to a
  ;;; field that represents a string command.
  (define (blockview-enter-string b keysym)
    (display "string entry")
    (newline))

  ;;; Dispatch entry events occuring on the blockview's content grid to the
  ;;; appropriate edit procedures, depending on field command type.
  (define (blockview-dispatch-entry-event b keysym)
    (unless (null? (blockview-get-current-field-value b))
      (let ((cmd (blockview-get-current-field-command b)))
	(if (command-has-flag? cmd 'is-note)
	    (blockview-enter-note b keysym)
	    (case (command-type cmd)
	      ((trigger) (blockview-enter-trigger b))
	      ((int uint) (blockview-enter-numeric b keysym))
	      ((key ukey) (blockview-enter-key b keysym))
	      ((reference) (blockview-enter-reference b keysym))
	      ((string) (blockview-enter-string b keysym)))))))

  ;;; Bind common event handlers for the blockview `b`.
  (define (blockview-bind-events b)
    (let ((grid (blockview-content-grid b)))
      (tk/bind* grid '<<BlockMotion>>
		`(,(lambda (keysym)
		     (blockview-move-cursor b keysym))
		  %K))
      (tk/bind* grid '<Button-1>
		(lambda () (blockview-set-cursor-from-mouse b)))
      (tk/bind* grid '<<ClearStep>>
		(lambda ()
		  (unless (null? (blockview-get-current-field-value b))
		    (blockview-edit-current-cell b '()))))
      (tk/bind* grid '<<CutStep>>
		(lambda () (blockview-cut-current-cell b)))
      (tk/bind* grid '<<InsertStep>>
		(lambda () (blockview-insert-cell b)))
      (tk/bind* grid '<<BlockEntry>>
		`(,(lambda (keysym)
		     (blockview-dispatch-entry-event b keysym))
		  %K))))

  ;;; Update the blockview display.
  ;;; The procedure attempts to be "smart" about updating, ie. it tries to not
  ;;; perform unnecessary updates. This makes the procedure fast enough to be
  ;;; used after any change to the blockview's content, rather than manually
  ;;; updating the part of the content that has changed.
  ;; TODO storing/restoring insert mark position is a cludge. Generally we want
  ;; the insert mark to move if stuff is being inserted above it.
  (define (blockview-update b)
    (let ((new-item-list (blockview-get-item-list b)))
      (unless (equal? new-item-list (blockview-item-cache b))
	(let ((current-mark-pos ((blockview-content-grid b) 'index 'insert)))
	  (if (or (not (= (length new-item-list)
			  (length (blockview-item-cache b))))
		  (not (equal? (map length new-item-list)
			       (map length (blockview-item-cache b)))))
	      (begin
		(blockview-item-cache-set! b new-item-list)
		(blockview-update-content-grid b)
		(blockview-update-row-numbers b)
		((blockview-content-grid b) 'mark 'set 'insert current-mark-pos)
		(blockview-tag-active-zone b)
		(when (eq? 'block (blockview-type b))
		  (blockview-update-row-highlights b)))
	      (begin
		(blockview-update-content-rows b new-item-list)
		((blockview-content-grid b) 'mark 'set 'insert current-mark-pos)
		(blockview-item-cache-set! b new-item-list)))))))

  ;;; Pack the blockview widget `b` to the screen.
  (define (blockview-show b)
    (let ((block-type? (eq? 'block (blockview-type b)))
	  (rownums (blockview-rownums b))
	  (rownum-header (blockview-rownum-header b))
	  (content-header (blockview-content-header b))
	  (content-grid (blockview-content-grid b)))
      (rownums 'configure width: (if block-type? 6 5)
	       yscrollcommand: `(,(blockview-yscroll b) set))
      (rownum-header 'configure height: (if block-type? 2 1)
		     width: (if block-type? 6 5))
      (content-header 'configure height: (if block-type? 2 1))
      (configure-scrollbar-style (blockview-xscroll b))
      (configure-scrollbar-style (blockview-yscroll b))
      (tk/pack (blockview-xscroll b) fill: 'x side: 'bottom)
      (tk/pack (blockview-packframe b) expand: 1 fill: 'both side: 'bottom)
      (tk/pack (blockview-header-frame b) fill: 'x side: 'bottom)
      (tk/pack (blockview-yscroll b) fill: 'y side: 'right)
      (tk/pack (blockview-rownum-frame b) fill: 'y side: 'left)
      (tk/pack rownum-header padx: '(4 0) side: 'top)
      (tk/pack rownums expand: 1 fill: 'y padx: '(4 0) side: 'top)
      (tk/pack (blockview-content-frame b) fill: 'both side: 'right)
      (tk/pack (blockview-content-header b)
	       fill: 'x side: 'top)
      (blockview-init-content-header b)
      (tk/pack content-grid expand: 1 fill: 'both side: 'top)
      (content-grid 'configure xscrollcommand: `(,(blockview-xscroll b) set)
		    yscrollcommand: `(,(blockview-yscroll b) set))
      (content-grid 'mark 'set 'insert "1.0")
      (blockview-bind-events b)
      (blockview-update b)))


  ;; ---------------------------------------------------------------------------
  ;;; ## Block Related Widgets and Procedures
  ;; ---------------------------------------------------------------------------

  ;;; A metawidget for displaying a group's block members and the corresponding
  ;;; order or block list.
  ;;; TODO MDAL defines order/block lists as optional if blocks are
  ;;; single instance.
  (defstruct bt-blocks-widget
    (tl-panedwindow : procedure)
    (blocks-view : (struct blockview))
    (order-view : (struct blockview)))

  ;;; Create a `bt-blocks-widget`.
  (define (make-blocks-widget parent-node-id parent-widget)
    (let ((block-ids (config-get-subnode-type-ids parent-node-id
						  (current-config)
						  'block)))
      (and (not (null? block-ids))
	   (let* ((.tl (parent-widget 'create-widget 'panedwindow
				      orient: 'horizontal))
		  (.blocks-pane (.tl 'create-widget 'frame))
		  (.order-pane (.tl 'create-widget 'frame)))
	     (.tl 'add .blocks-pane weight: 2)
	     (.tl 'add .order-pane weight: 1)
	     (make-bt-blocks-widget
	      tl-panedwindow: .tl
	      blocks-view: (blockview-create .blocks-pane 'block parent-node-id)
	      order-view: (blockview-create .order-pane 'order
					    parent-node-id))))))

  ;;; Display a `bt-blocks-widget`.
  (define (show-blocks-widget w)
    (let ((top (bt-blocks-widget-tl-panedwindow w)))
      (tk/pack top expand: 1 fill: 'both)
      (blockview-show (bt-blocks-widget-blocks-view w))
      (blockview-show (bt-blocks-widget-order-view w))))

  ;;; The "main view" metawidget, displaying all subgroups of the GLOBAL node in
  ;;; a notebook (tabs) tk widget. It can be indirectly nested through a
  ;;; bt-group-widget, which is useful for subgroups that have subgroups
  ;;; themselves.
  ;;; bt-subgroups-widgets should be created through `make-subgroups-widget`.
  (defstruct bt-subgroups-widget
    (toplevel-frame : procedure)
    (subgroup-ids : (list-of symbol))
    (tl-notebook : procedure)
    (notebook-frames : (list-of procedure))
    (subgroups : (list-of (struct bt-group-widget))))

  ;;; Create a `bt-subgroups-widget` as child of `parent-widget`.
  (define (make-subgroups-widget parent-node-id parent-widget)
    (let ((sg-ids (config-get-subnode-type-ids parent-node-id
					       (current-config)
					       'group)))
      (and (not (null? sg-ids))
	   (let* ((tl-frame (parent-widget 'create-widget 'frame))
		  (notebook (tl-frame 'create-widget 'notebook
				      style: 'BT.TNotebook))
		  (subgroup-frames (map (lambda (id)
					  (notebook 'create-widget 'frame))
					sg-ids)))
	     (make-bt-subgroups-widget
	      toplevel-frame: tl-frame
	      subgroup-ids: sg-ids
	      tl-notebook: notebook
	      notebook-frames: subgroup-frames
	      subgroups: (map make-group-widget sg-ids subgroup-frames))))))

  ;;; Pack a bt-subgroups-widget to the display.
  (define (show-subgroups-widget w)
    (tk/pack (bt-subgroups-widget-toplevel-frame w)
	     expand: 1 fill: 'both)
    (tk/pack (bt-subgroups-widget-tl-notebook w)
	     expand: 1 fill: 'both)
    (for-each (lambda (sg-id sg-frame)
		((bt-subgroups-widget-tl-notebook w)
		 'add sg-frame text: (symbol->string sg-id)))
	      (bt-subgroups-widget-subgroup-ids w)
	      (bt-subgroups-widget-notebook-frames w))
    (for-each show-group-widget (bt-subgroups-widget-subgroups w)))

  ;; Not exported.
  (defstruct bt-group-widget
    (node-id : symbol)
    (toplevel-frame : procedure)
    (fields-widget : (struct bt-fields-widget))
    (blocks-widget : (struct bt-blocks-widget))
    (subgroups-widget : (struct bt-subgroups-widget)))

  ;; TODO handle groups with multiple instances
  (define (make-group-widget node-id parent-widget)
    (let ((tl-frame (parent-widget 'create-widget 'frame)))
      (make-bt-group-widget
       node-id: node-id
       toplevel-frame: tl-frame
       fields-widget: (make-fields-widget node-id tl-frame)
       blocks-widget: (make-blocks-widget node-id tl-frame)
       subgroups-widget: (make-subgroups-widget node-id tl-frame))))

  ;;; Display the group widget (using pack geometry manager).
  (define (show-group-widget w)
    (let ((instance-path (get-current-instance-path
			  (bt-group-widget-node-id w))))
      (tk/pack (bt-group-widget-toplevel-frame w)
	       expand: 1 fill: 'both)
      (when (bt-group-widget-fields-widget w)
	(show-fields-widget (bt-group-widget-fields-widget w)
			    instance-path))
      (when (bt-group-widget-blocks-widget w)
	(show-blocks-widget (bt-group-widget-blocks-widget w)))
      (when (bt-group-widget-subgroups-widget w)
	(show-subgroups-widget (bt-group-widget-subgroups-widget w)))
      (unless (or (bt-group-widget-blocks-widget w)
		  (bt-group-widget-subgroups-widget w))
	(tk/pack ((bt-group-widget-toplevel-frame w)
		  'create-widget 'frame)
		 expand: 1 fill: 'both))))

  (define (destroy-group-widget w)
    (tk/destroy (bt-group-widget-toplevel-frame w)))

  (define (make-module-widget parent)
    (make-group-widget 'GLOBAL parent))

  (define (show-module)
    (show-group-widget (state 'module-widget)))

  ;; ---------------------------------------------------------------------------
  ;;; ## Accessors
  ;; ---------------------------------------------------------------------------

  (define (current-fields-view)
    (bt-group-widget-fields-widget (state 'module-widget)))

  ;;; Returns the currently visible blocks metatree
  ;; TODO assumes first subgroup is shown, check actual state
  (define (current-blocks-view)
    (bt-blocks-widget-blocks-view
     (bt-group-widget-blocks-widget
      (car (bt-subgroups-widget-subgroups
	    (bt-group-widget-subgroups-widget (state 'module-widget)))))))

  ;;; Returns the currently visible order metatree
  ;; TODO assumes first subgroup is shown, check actual state
  (define (current-order-view)
    (bt-blocks-widget-order-view
     (bt-group-widget-blocks-widget
      (car (bt-subgroups-widget-subgroups
	    (bt-group-widget-subgroups-widget (state 'module-widget)))))))


  ) ;; end module bt-gui
