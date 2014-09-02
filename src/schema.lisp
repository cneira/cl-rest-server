(in-package :rest-server)

;; Schemas

;; Schemas may be used either to serialize objects or validate input

(defgeneric serialize-with-schema (schema input &optional serializer stream)
  (:documentation "Serialize input using schema")
  (:method (schema input &optional (serializer *serializer*) (stream *serializer-output*))
    (%serialize-with-schema schema serializer input stream)))

(defmethod %serialize-with-schema (schema serializer input stream)
  (if (listp schema)
      (ecase (first schema)
	(:list (serialize-schema-list schema serializer input stream))
	(:option (serialize-value serializer input stream))
	(:element (serialize-schema-element schema serializer input stream)))))

(defun serialize-schema-element (schema-element serializer input stream)
  (destructuring-bind (_ element-name attributes &rest options) schema-element
    (declare (ignore _))
    (with-element ((or (and (stringp element-name)
			    element-name)
		       (symbol-name element-name))
		   :serializer serializer
		   :stream stream)
      (loop for attribute in attributes
	   do
	   (serialize-schema-attribute attribute serializer input stream)))))

(defun serialize-schema-attribute (schema-attribute serializer input stream)
  (destructuring-bind 
	(attribute-name attribute-type &rest options)
      schema-attribute
    (let* ((accessor (symbol-function (or (getf options :accessor) attribute-name)))
	   (attribute-value (funcall accessor input)))
      (when (not (and (getf options :optional) (not attribute-value)))
	(with-attribute (attribute-name :serializer serializer
					:stream stream)
	  (cond
	    ((getf options :serializer)
	     (funcall (getf options :serializer) attribute-value))
	    ((keywordp attribute-type)
	     (serialize-attribute-value attribute-type attribute-value stream serializer))
	    ((symbolp attribute-type)
	     ;; It is a schema reference or a serializable class reference
	     (let ((attribute-schema (find-schema attribute-type nil)))
	       (if attribute-schema
		   (%serialize-with-schema attribute-schema serializer attribute-value stream)
		   ; else, try with a serializable class reference
		   (let ((serializable-class (find-class attribute-type nil)))
		     (if (and serializable-class
			      (typep serializable-class 'serializable-class))
			 (%serialize-with-schema (serializable-class-schema serializable-class)
						 serializer attribute-value stream)
			 ; else
			 (error "Could not resolve reference ~A when serializing" attribute-type))))))
	    ((listp attribute-type)
	     (%serialize-with-schema attribute-type
				     serializer
				     attribute-value
				     stream))))))))

(defmethod serialize-attribute-value (attribute-type attribute-value stream &optional (serializer *serializer*))
  (serialize attribute-value serializer stream))

(defmethod serialize-attribute-value ((attribute-type (eql :timestamp)) attribute-value stream &optional (serializer *serializer*))
  (if (integerp attribute-value)
      ;; Assume a universal time number
      (write (net.telent.date:universal-time-to-rfc-date attribute-value) :stream stream)
      ;; else, serialize whatever it is
      (call-next-method)))

(defmethod serialize ((thing local-time:timestamp)
		      &optional (serializer *serializer*)
			(stream *serializer-output*) &rest args)
  (local-time:format-rfc1123-timestring stream thing)) 

(defun serialize-schema-list (schema-list serializer input stream)
  (destructuring-bind (_ list-type) schema-list
    (declare (ignore _))
    (with-list ("LIST" :serializer serializer
				:stream stream)
      (cond 
	((keywordp list-type)
	 ;; It is a primitive type like :string, :boolean, etc
	 (loop for elem in input
	    do
	      (add-list-member "ITEM" elem
			       :serializer serializer
			       :stream stream)))
	((symbolp list-type)
	 ;; It is a reference to a schema like 'user-schema'
	 (let ((schema (find-schema list-type)))
	   (loop for elem in input
	      do
		(with-list-member ("ITEM" :serializer serializer
					  :stream stream)
		  (%serialize-with-schema schema serializer elem stream)))))
	((listp list-type)
	 ;; It is some compound type, like :element, :list, or :option
	 (let ((schema list-type))
	   (loop for elem in input
	      do
		(with-list-member ("ITEM" :serializer serializer
					  :stream stream)
		  (%serialize-with-schema schema serializer elem stream)))))))))

(defvar *schemas* (make-hash-table))

(defun register-schema (name definition)
  (setf (gethash name *schemas*)
	definition))

(defmacro define-schema (name schema)
  "Define a schema"
  `(register-schema ',name
		    (schema ,schema)))

(defmacro schema (schema-def)
  `(quote ,schema-def))

(defun find-schema (name &optional (errorp t))
  "Find a schema definition by name"
  (multiple-value-bind (schema foundp)
      (gethash name *schemas*)
    (if (not foundp)
	(if errorp
	    (error "Schema ~a not found" name)
	    nil)
	schema)))

(defun validate-with-schema (schema string-or-data &optional (format :json))
  "Validate input using schema. Useful for validate api function posted content (for :post and :put methods). Input can be a string or an association list."
  (let ((data (if (stringp string-or-data)
		  (parse-api-input format string-or-data)
		  string-or-data)))
    (schema-validate-with-element schema data)))

(define-condition validation-error (simple-error)
  ())

(defun validation-error (message &rest args)
  (error 'validation-error :format-control message
	 :format-arguments args))

(defun schema-validate-with-element (schema data)
  "Validate data using schema element. "
  (loop
     for schema-attribute in (element-attributes schema)
     for data-attribute = (assoc (string (attribute-name schema-attribute))
				  data
				  :test #'equalp
				  :key #'string)
     do
       (when (and (not data-attribute)
		  (not (attribute-optional-p schema-attribute)))
	 (validation-error "Attribute ~a not found in ~a"
			   (attribute-name schema-attribute)
			   data))
       (when (not (schema-typep (cdr data-attribute)
				(attribute-type schema-attribute)))
	 (validation-error "~A is not of type ~A"
			   (cdr data-attribute)
			   (attribute-type schema-attribute)))))

(defgeneric schema-typep (value type)
  (:method (value (type (eql :string)))
    (stringp value))
  (:method (value (type (eql :integer)))
    (numberp value))
  (:method (value (type (eql :list)))
    (listp value))
  (:method (value (type (eql :date)))
    (or (typep value 'local-time:timestamp)
	(and (stringp value)
	     (chronicity:parse value)))))

(defgeneric parse-api-input (format string)
  (:documentation "Parses content depending on its format"))

(defmethod parse-api-input ((format (eql :json)) string)
  (json:decode-json-from-string string)) 

(defun fold-tree (f g tree)
  (if (listp tree)
      (let ((name (first tree))
	    (children (cdr tree)))
	(funcall f
		 (cons name (mapcar (lambda (child)
				      (fold-tree f g child))
				    children))))
	(funcall g tree)))

(defmethod parse-api-input ((format (eql :xml)) string)
  (let ((data
	 (cxml:parse string (make-xmls-builder))))
    (fold-tree (lambda (node)
		 (cond
		   ((equalp (car node) "_ITEM")
		    ;; It is a list item
		    (cons :li (string-trim '(#\") (cadr node))))
		   ((equalp (aref (car node) 0) #\_)
		    ;; It is an object
		    (cdr node))
		   ((stringp (cadr node))
		    (cons (make-keyword (first node))
			  (string-trim '(#\") (cadr node))))
		   ((and (listp (cadr node))
			 (equalp (first (cadr node)) :li))
			;; The attribute value is a list
			(cons (make-keyword (first node))
			      (mapcar #'cdr (cdr node))))
		   (t
		    (let ((attr-name (make-keyword (first node)))
			  (attr-value (cdr node)))
		      (cons attr-name attr-value)))))
	       #'identity
	       data)))

(defmethod parse-api-input ((format (eql :sexp)) string)
  (read-from-string string))

(defgeneric parse-with-schema (schema string-or-data &optional format)
  (:documentation "Parses the string to an association list using the schema"))

(defmethod parse-with-schema ((schema symbol) string-or-data &optional (format :json))
  (parse-with-schema (find-schema schema) string-or-data format))

(defmethod parse-with-schema (schema string-or-data &optional (format :json))
  (let ((data
	 (if (stringp string-or-data)
	     (parse-api-input format string-or-data)
	     string-or-data)))
    (%parse-with-schema (schema-type schema)
			schema
			data)))

(defmethod %parse-with-schema ((schema-type (eql :element))
			       schema data)
  (if (null data)
      data
      (loop
	 for schema-attribute in (element-attributes schema)
	 for data-attribute = (assoc (string (attribute-name schema-attribute))
				     data
				     :test #'equalp
				     :key #'string)
	 appending
	   (progn
	     (when (and (not data-attribute)
			(not (attribute-optional-p schema-attribute)))
	       (validation-error "Attribute ~a not found in ~a"
				 (attribute-name schema-attribute)
				 data))
	     (when (or (equalp (attribute-type schema-attribute) :boolean)
		       (not (null (cdr data-attribute))))
	       (list (cons (attribute-name schema-attribute)
			   (parse-schema-attribute-value (attribute-type schema-attribute)
							 (cdr data-attribute)))))))))

(defmethod %parse-with-schema ((schema-type (eql :list))
			       schema data)
  (let ((list-schema (second schema)))
    (loop for elem in data
	 collect (parse-with-schema list-schema elem))))

(defmethod parse-schema-attribute-value ((type (eql :string)) data)
  (string data))

(defmethod parse-schema-attribute-value ((type (eql :integer)) data)
  (cond
    ((integerp data)
     data)
    ((stringp data)
     (parse-integer data))
    (t (validation-error "~A is not an integer" data))))

(defmethod parse-schema-attribute-value ((type (eql :timestamp)) data)
  (chronicity:parse data))

(defmethod parse-schema-attribute-value ((type (eql :time)) data)
  (chronicity:parse data))

(defmethod parse-schema-attribute-value ((type (eql :date)) data)
  (chronicity:parse data))

(defmethod parse-schema-attribute-value ((type symbol) data)
  (let ((schema (find-schema type)))
    (parse-with-schema schema data)))

(defmethod parse-schema-attribute-value ((type cons) data)
  (parse-with-schema type data))

(defun schema-type (schema)
  (first schema))

(defun parse-xml-with-schema (schema-or-name input)
  (let ((schema (if (symbolp schema-or-name)
		    (find-schema schema-or-name)
		    schema-or-name)))
  
    (ecase (schema-type schema)
      (:list
       (let ((items (third input)))
	 (loop for item in items
	    collect
	      (parse-xml-with-schema
	       (second schema) ;; the list type
	       item))))
      (:element
       (assert (equalp (make-keyword (element-name schema))
		       (make-keyword (first input))) nil
		       "~A is not a ~A" input (element-name schema))
       (loop for attribute in (element-attributes schema)
	  appending (let ((input-attribute
			   (find (symbol-name (attribute-name attribute))
				 (cddr input)
				 :key #'first
				 :test #'equalp)))
		      (if input-attribute
			  ;; The attrbute is present
			  (list (cons (make-keyword (first input-attribute))
				      (cond
					((listp (attribute-type attribute))
					 ;; It is a compound type (:list, :element, etc)
					 (parse-xml-with-schema
					  (second (attribute-type attribute)) ;; The compound element type
					  (third input-attribute) ;; The attribute value
					  ))
					((keywordp (attribute-type attribute))
					 ;; the attribute type is simple, parse the attribute value
					 (unserialize-schema-attribute-value
					  (attribute-type attribute)
					  (third input-attribute)))
					((symbolp (attribute-type attribute))
					 ;; assume a schema reference
					 (let ((attribute-schema (find-schema (attribute-type attribute))))
					   (parse-xml-with-schema
					    attribute-schema
					    (third input-attribute) ;; The attribute value
					    )))))))))))))

(defun element-name (element)
  (second element))

(defun element-attributes (element)
  (third element))

(defun find-element-attribute (element attribute-name &key (error-p t))
  (loop for attribute in (element-attributes element)
       when (equalp (string (attribute-name attribute))
		    (string attribute-name))
       do (return-from find-element-attribute attribute))
  (when error-p
    (error "Attribute ~A not found in ~A" attribute-name element)))

(defun element-options (element)
  (cdddr element))

(defun element-option (option element)
  (find option (element-options element) :key #'car))

(defun attribute-name (attribute)
  (first attribute))

(defun attribute-type (attribute)
  (second attribute))

(defun attribute-type-name (attribute)
  (let ((attribute-type (attribute-type attribute)))
    (if (listp attribute-type)
	(first attribute-type)
	attribute-type)))  

(defun attribute-options (attribute)
  (cddr attribute))

(defun attribute-option (option attribute)
  (getf (attribute-options attribute) option))

(defun attribute-optional-p (attribute)
  (attribute-option :optional attribute))

(defun attribute-accessor (attribute)
  (attribute-option :accessor attribute))

(defun attribute-writer (attribute)
  (attribute-option :writer attribute))

(defun attribute-reader (attribute)
  (attribute-option :reader attribute))

;; Unserialization

(defun element-class (element)
  "Returns the CLOS class associated with an element. May be null."
  (let ((element-class (element-option :class element)))
    (second element-class)))

(defun element-unserializer (element)
  "Returns the unserializer of the element if any"
  (let ((unserializer (element-option :unserializer element)))
    (second unserializer)))  

;; (element-unserializer '(:element user () (:unserializer unserialize-user)))

(defun unserialize-with-schema (schema string-or-data &optional (format :json))
  (let ((data (if (stringp string-or-data)
		  (parse-api-input format string-or-data)
		  string-or-data)))
    (unserialize-schema-element schema data)))  

(defun unserialize-schema-element (element input)
  "Unserializes an schema element

Args: - element (list) : An schema element
      - input (assoc-list) : An association list with values.
                             Probably obtained from parse-api-input.

See: parse-api-input (function)"
  
  (let ((unserializer (element-unserializer element))
	(element-class (element-class element)))
    (cond
      (unserializer (funcall unserializer input))
      (element-class (unserialize-schema-element-to-class element input element-class))
      (t input))))

(defun unserialize-schema-element-to-class (element input class)
  (let ((instance (allocate-instance (find-class class))))
    (loop for attribute in (element-attributes element)
       do (let ((attribute-input (assoc (string (attribute-name attribute))
					input
					:test #'equalp
					:key #'string)))
	    (when (and (not attribute-input)
		       (not (attribute-optional-p attribute)))
	      (validation-error "~A not provided" (attribute-name attribute)))
	    (let ((attribute-value (unserialize-schema-attribute attribute (cdr attribute-input))))
	      (setf (slot-value instance (or (attribute-option :slot attribute)
					     (attribute-name attribute)))
		    attribute-value))))
    (initialize-instance instance)
    instance))

(defun unserialize-schema-attribute (attribute input)
  (let ((unserializer (attribute-option :unserializer attribute)))
    (if unserializer
	(funcall unserializer)
	(if (null input)
	    (when (not (attribute-optional-p attribute))
	      (validation-error
	       "Attribute ~A is not optional but value was not provided"
	       (attribute-name attribute)))
	    ; else
	    (unserialize-schema-attribute-value (attribute-type attribute) input)))))

(defun unserialize-schema-attribute-value (type input)
  (%unserialize-schema-attribute-value
   (if (listp type)
       (first type)
       type)
   type
   input))

(defgeneric %unserialize-schema-attribute-value (type-name type input)
  (:method ((type-name (eql :integer)) attribute input)
    (if (integerp input)
	input
	(parse-integer input)))
  (:method ((type-name (eql :string)) type input)
    input)
  (:method ((type-name (eql :boolean)) type input)
    (if (stringp input)
	(let ((true-strings (list "true" "t" "yes" "on"))
	      (false-strings (list "false" "f" "no" "off")))
	  (assert (member input (append true-strings false-strings) :test #'equalp)
		  nil "Invalid boolean ~A" input)
	  (member input true-strings :test #'equalp))
	(not (null input))))
  (:method ((type-name (eql :element)) type input)
    (unserialize-schema-element type input))
  (:method ((type-name (eql :list)) type input)
    (let ((list-type (second type)))
      (loop for elem in input
	 collect (unserialize-schema-attribute-value list-type elem))))
  (:method ((type-name (eql :option)) type input)
    input)
  (:method (type-name type input)
    ;; Assume a schema reference
    (let ((schema (find-schema type-name nil)))
      (if (not schema)
	  (error "Invalid type ~A" type-name)
					; else
	  (unserialize-schema-attribute-value schema input)))))

;; Plugging

;; Validation

(defclass validation-api-function-implementation-decoration
    (api-function-implementation-decoration)
  ((schema :initarg :schema
	   :accessor validation-schema
	   :initform (error "Provide the validation schema"))
   (format :initarg :format
	   :accessor validation-format
	   :initform :json))
  (:metaclass closer-mop:funcallable-standard-class))
  
(defmethod process-api-function-implementation-option
    ((option (eql :validation))
     api-function-implementation
     &key (enabled t)
       (schema (error "Provide the validation schema"))
       (format :json))
  (if enabled
      (make-instance 'validation-api-function-implementation-decoration
		     :schema schema
		     :format format
		     :decorates api-function-implementation)
      api-function-implementation))
  
(defmethod execute :around ((decoration validation-api-function-implementation-decoration)
			    &rest args)
  (let ((posted-content (first args))) ;; Asume the posted content is in the first argument
    (let ((valid-p (validate-with-schema (validation-schema decoration)
					 posted-content
					 (validation-format decoration))))
      (if (not valid-p)
	  (error "The posted content is invalid")
	  (call-next-method)))))

(cl-annot:defannotation validation (args api-function-implementation)
    (:arity 2)
  `(configure-api-function-implementation
    (name (api-function ,api-function-implementation))
    (list :validation ,@args)))

;; Unserialization

(defclass unserialization-api-function-implementation-decoration
    (api-function-implementation-decoration)
  ((schema :initarg :schema
	   :accessor unserialization-schema
	   :initform (error "Provide the unserialization schema"))
   (format :initarg :format
	   :accessor unserialization-format
	   :initform :json))
  (:metaclass closer-mop:funcallable-standard-class))
  
(defmethod process-api-function-implementation-option
    ((option (eql :unserialization))
     api-function-implementation
     &key (enabled t)
       (schema (error "Provide the unserialization schema"))
       (format :json))
  (if enabled
      (make-instance 'unserialization-api-function-implementation-decoration
		     :schema schema
		     :format format
		     :decorates api-function-implementation)
      api-function-implementation))
  
(defmethod execute :around ((decoration unserialization-api-function-implementation-decoration)
			    &rest args)
  (let ((posted-content (first args))) ;; Asume the posted content is in the first argument
    (apply #'call-next-method
	   (unserialize-with-schema (unserialization-schema decoration)
				    posted-content
				    (unserialization-format decoration))
	   (rest args))))

(cl-annot:defannotation unserialization (args api-function-implementation)
    (:arity 2)
  `(configure-api-function-implementation
    (name (api-function ,api-function-implementation))
    (list :unserialization ,@args)))
