(in-package :rest-server)

(defparameter *element*
  (element "user"
           (attribute "id" 22)
           (attribute "realname" "Mike")
           (attribute "groups"
                      (elements "groups"
                                (element "group"
                                         (attribute "id" 33)
                                         (attribute "title" "My group"))))))

(with-serializer-output t
  (with-serializer :json
    (serialize *element*)))

(cxml:with-xml-output (cxml:make-character-stream-sink t :indentation nil :omit-xml-declaration-p t)
  (with-serializer-output t
    (with-serializer :xml
      (serialize *element*))))

(with-serializer-output t
  (with-serializer :sexp
    (serialize *element*)))

(defpackage :api-test
  (:use :rest-server :cl))

(in-package :api-test)

(define-api api-test
  (:version 1
   :uri-prefix "v1/"
     :documentation "This is an api test"
     :content-types (list :json :xml))
  (get-users (:method :get
              :content-types (list :json)
              :uri-prefix "/users"
              :documentation "Retrive the users list")       
             (&optional (expand-groups :boolean nil)))
  (get-user (:method :get
             :content-types (list :json)
             :uri-prefix "/users/{id :integer}"
             :documentation "Retrive an user")
            ((id :string) &optional (expand-groups :boolean nil)))
  (create-user (:method :post
                :content-types (list :json)
                :uri-prefix "/users"
                :documentation "Create a user")
               ())
  (update-user (:method :put
                 :content-types (list :json)
                 :uri-prefix "/users/{id :integer}"
                 :documentation "Update a user")
               ((id :string)))
  (delete-user (:method :delete
                 :content-types (list :json)
                 :uri-prefix "/users/{id :integer}"
                 :documentation "Delete a user")
               ((id :string))))

(defpackage :api-test-implementation
  (:use :cl :rest-server))

(in-package :api-test-implementation)

(defun get-users ()
  (list "user1" "user2" "user3"))

(defun get-user (id)
  "user1")

(defun create-user (posted-content)
  (break "Create user: ~A" posted-content))

(defun update-user (id posted-content)
  (break "Update user: ~A ~A" id posted-content))

(defun delete-user (id)
  (break "Delete user: ~A" id))