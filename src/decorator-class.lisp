(in-package :rest-server)

(defclass decorator-class (standard-class)
  ())

(defmethod closer-mop:validate-superclass ((class decorator-class)
					   (superclass standard-class))
    t)

(defclass decorated-slot-definition (closer-mop:standard-slot-definition)
  ((decorate
    :initform t
    :type boolean
    :accessor decorate-slot-p
    :initarg :decorate)))

;; Slots

(defclass decorated-direct-slot-definition (decorated-slot-definition closer-mop:standard-direct-slot-definition)
  ())

(defclass decorated-effective-slot-definition (decorated-slot-definition closer-mop:standard-effective-slot-definition)
  ())

(defmethod closer-mop:direct-slot-definition-class ((class decorator-class) &rest initargs)
  (declare (ignore initargs))
  (find-class 'decorated-direct-slot-definition))

(defmethod closer-mop:effective-slot-definition-class ((class decorator-class) &rest initargs)
  (declare (ignore initargs))
  (find-class 'decorated-effective-slot-definition))

(defmethod closer-mop:compute-effective-slot-definition
    ((class decorator-class)
     slot-name direct-slots)
  (declare (ignore slot-name))
  (let ((effective-slot (call-next-method)))
    (setf (decorate-slot-p effective-slot)
	  (some #'decorate-slot-p direct-slots))
    effective-slot))

(defclass decorator-object (standard-object)
  ((decoratee :initarg :decoratee
	      :initform (error "Provide the decoratee")
	      :accessor decoratee
	      :documentation "The object being decorated"
	      :decorate nil))
  (:metaclass decorator-class))

(defmethod initialize-instance :around
  ((class decorator-class) &rest initargs
   &key direct-superclasses)
  (declare (dynamic-extent initargs))
  (if (loop for class in direct-superclasses
            thereis (subtypep class (find-class 'decorator-object)))

     ;; 'my-object is already one of the (indirect) superclasses
     (call-next-method)

     ;; 'my-object is not one of the superclasses, so we have to add it
     (apply #'call-next-method
            class
            :direct-superclasses
            (append direct-superclasses
                    (list (find-class 'decorator-object)))
            initargs)))

(defmethod reinitialize-instance :around
  ((class decorator-class) &rest initargs
   &key (direct-superclasses '() direct-superclasses-p))
  (declare (dynamic-extent initargs))
  (if direct-superclasses-p

    ;; if direct superclasses are explicitly passed
    ;; this is exactly like above
    (if (loop for class in direct-superclasses
              thereis (subtypep class (find-class 'decorator-object)))
       (call-next-method)
       (apply #'call-next-method
              class
              :direct-superclasses
              (append direct-superclasses
                      (list (find-class 'decorator-object)))
              initargs))

    ;; if direct superclasses are not explicitly passed
    ;; we _must_ not change anything
    (call-next-method)))

(defmethod closer-mop:slot-value-using-class :around
    ((class decorator-class)
     (object decorator-object)
     slot)
  (if (not (decorate-slot-p slot))
      (call-next-method)
      (slot-value (decoratee object)
		  (closer-mop:slot-definition-name slot))))

(defmethod (setf closer-mop:slot-value-using-class) :around
    (new-value
     (class decorator-class)
     (object decorator-object)
     slot)
  (if (not (decorate-slot-p slot))
      (call-next-method)
      (setf (slot-value (decoratee object)
			(closer-mop:slot-definition-name slot))
	    new-value)))

(defmethod closer-mop:slot-boundp-using-class :around
    ((class decorator-class)
     (object decorator-object)
     slot)
  (if (not (decorate-slot-p slot))
      (call-next-method)
      (slot-boundp (decoratee object)
		   (closer-mop:slot-definition-name slot))))

(defmethod closer-mop:slot-makunbound-using-class :around
    ((class decorator-class)
     (object decorator-object)
     slot)
  (if (not (decorate-slot-p slot))
      (call-next-method)
      (slot-makunbound (decoratee object)
		       (closer-mop:slot-definition-name slot))))

(defmethod decorate-slot-p (slot)
  t)

(closer-mop:finalize-inheritance (find-class 'decorator-class))
(closer-mop:finalize-inheritance (find-class 'decorator-object))

;; Test

(defclass decoratee ()
  ((value :initform 22
	  :accessor value)))

(defclass decorator (decoratee)
  ()
  (:metaclass decorator-class))

(closer-mop:finalize-inheritance (find-class 'decorator))

(defparameter *o* (make-instance 'decoratee))

(value *o*)

(defparameter *d* (make-instance 'decorator :decoratee *o*))

(value *d*)
