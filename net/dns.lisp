;;;; Copyright (c) 2011-2016 Henry Harrington <henry.harrington@gmail.com>
;;;; This code is licensed under the MIT license.

(in-package :mezzano.network.dns)

(defvar *dns-servers* '())

(defvar +dns-port+ 53)
(defvar +dns-standard-query+ #x0100)

(defun add-dns-server (server &optional tag)
  (push (cons (mezzano.network.ip:make-ipv4-address server) tag) *dns-servers*))

(defun remove-dns-server (server &optional tag)
  (setf server (mezzano.network.ip:make-ipv4-address server))
  (setf *dns-servers*
        (remove-if (lambda (x)
                     (and (mezzano.network.ip:address-equal (car x) server)
                          (or (eql tag t)
                              (eql (cdr x) tag))))
                   *dns-servers*)))

(defun encode-dns-type (type)
  (ecase type
    (:a 1)
    (:ns 2)
    (:md 3)
    (:mf 4)
    (:cname 5)
    (:soa 6)
    (:mb 7)
    (:mg 8)
    (:mr 9)
    (:null 10)
    (:wks 11)
    (:ptr 12)
    (:hinfo 13)
    (:minfo 14)
    (:mx 15)
    (:txt 16)
    (:aaaa 28)))

(defun decode-dns-type (type)
  (case type
    (1 :a)
    (2 :ns)
    (3 :md)
    (4 :mf)
    (5 :cname)
    (6 :soa)
    (7 :mb)
    (8 :mg)
    (9 :mr)
    (10 :null)
    (11 :wks)
    (12 :ptr)
    (13 :hinfo)
    (14 :minfo)
    (15 :mx)
    (16 :txt)
    (28 :aaaa)
    (t (list :unknown-type type))))

(defun encode-dns-class (class)
  (ecase class
    (:in 1)
    (:cs 2)
    (:ch 3)
    (:hs 4)))

(defun decode-dns-class (class)
  (case class
    (1 :in)
    (2 :cs)
    (3 :ch)
    (4 :hs)
    (t (list :unknown-class class))))

(defun write-dns-name (packet offset name)
  (when (not (zerop (length name)))
    ;; Domain names can end in a #\., trim it off.
    (dolist (part (sys.int::explode #\. name 0 (if (eql #\. (char name (1- (length name))))
                                                   (1- (length name)))))
      (assert (<= (length part) 63))
      (assert (not (zerop (length part))))
      (setf (aref packet offset) (length part))
      (incf offset)
      (loop for c across part do
           (setf (aref packet offset) (char-code (char-downcase c)))
           (incf offset))))
  (setf (aref packet offset) 0)
  (incf offset)
  offset)

(defun build-dns-packet (id flags &key questions answers authority-rrs additional-rrs)
  (when (or answers authority-rrs additional-rrs)
    (error "TODO..."))
  (let ((packet (make-array 512 :element-type '(unsigned-byte 8) :initial-element 0))
        (offset 12))
    (setf (ub16ref/be packet  0) id
          (ub16ref/be packet  2) flags
          (ub16ref/be packet  4) (length questions)
          (ub16ref/be packet  6) 0 #+(or)(length answers)
          (ub16ref/be packet  8) 0 #+(or)(length authority-rrs)
          (ub16ref/be packet 10) 0 #+(or)(length additional-rrs))
    (loop for (name type class) in questions do
         (setf offset (write-dns-name packet offset name))
         (setf (ub16ref/be packet offset) (encode-dns-type type))
         (setf (ub16ref/be packet (+ offset 2)) (encode-dns-class class))
         (incf offset 4))
    (subseq packet 0 offset)))

(defun read-dns-name (packet offset)
  (let ((name (make-array 255 :element-type 'character :fill-pointer 0)))
    (labels ((read-section (offset)
               (let ((section-size 0))
                 (loop
                    (let ((leader (aref packet offset)))
                      (incf section-size)
                      (when (zerop leader)
                        (return))
                      (ecase (ldb (byte 2 6) leader)
                        (0 ;; Reading a label from the packet of length LEADER.
                         (dotimes (i leader)
                           (vector-push (code-char (aref packet (+ offset 1 i))) name))
                         (incf section-size leader)
                         (incf offset (1+ leader))
                         (vector-push #\. name))
                        (3 ;; Following a pointer.
                         (let ((pointer (ldb (byte 14 0) (ub16ref/be packet offset))))
                           ;; Make sure it doesn't point to a pointer.
                           ;; This is probably permitted, but seems like a bad idea.
                           (when (eql (ldb (byte 2 6) (aref packet pointer)) 3)
                             (error "Pointer points directly to pointer."))
                           (read-section pointer)
                           (incf section-size)
                           (return))))))
                 section-size)))
      (incf offset (read-section offset))
      (when (not (zerop (length name)))
        ;; Snip trailing #\.
        (decf (fill-pointer name)))
      (values name offset))))

(defun decode-resource-record-data (type class packet offset data-len)
  (when (not (eql class :in))
    (return-from decode-resource-record-data (list (subseq packet offset (+ offset data-len)))))
  (case type
    ((:cname :ptr :mb :md :mf :mg :mr :ns) (list (read-dns-name packet offset)))
    (:mx (list (ub16ref/be packet offset) (read-dns-name packet (+ offset 2))))
    (:a (list (ub32ref/be packet offset)))
    (:soa (multiple-value-bind (mname next-offset)
              (read-dns-name packet offset)
            (multiple-value-bind (rname next-offset)
                (read-dns-name packet next-offset)
              (let ((serial (ub32ref/be packet next-offset))
                    (refresh (ub32ref/be packet (+ next-offset 4)))
                    (retry (ub32ref/be packet (+ next-offset 8)))
                    (expire (ub32ref/be packet (+ next-offset 12)))
                    (minimum (ub32ref/be packet (+ next-offset 16))))
                (list mname rname serial refresh retry expire minimum)))))
    (t (list (subseq packet offset (+ offset data-len))))))

(defun decode-dns-packet (packet)
  (let ((id (ub16ref/be packet 0))
        (flags (ub16ref/be packet 2))
        (qdcount (ub16ref/be packet 4))
        (ancount (ub16ref/be packet 6))
        (nscount (ub16ref/be packet 8))
        (arcount (ub16ref/be packet 10))
        (questions '())
        (answers '())
        (authority-records '())
        (additional-records '())
        (offset 12))
    (dotimes (i qdcount)
      (multiple-value-bind (name next-offset)
          (read-dns-name packet offset)
        (setf offset next-offset)
        (let ((type (decode-dns-type (ub16ref/be packet offset)))
              (class (decode-dns-class (ub16ref/be packet (+ offset 2)))))
          (incf offset 4)
          (push (list name type class) questions))))
    (flet ((decode-resource-record ()
             (multiple-value-bind (name next-offset)
                 (read-dns-name packet offset)
               (setf offset next-offset)
               (let ((type (decode-dns-type (ub16ref/be packet offset)))
                     (class (decode-dns-class (ub16ref/be packet (+ offset 2))))
                     (ttl (ub32ref/be packet (+ offset 4)))
                     (data-len (ub16ref/be packet (+ offset 8))))
                 (incf offset 10)
                 (prog1
                     (list* name type class ttl (decode-resource-record-data type class packet offset data-len))
                   (incf offset data-len))))))
      (dotimes (i ancount)
        (push (decode-resource-record) answers))
      (dotimes (i nscount)
        (push (decode-resource-record) authority-records))
      (dotimes (i arcount)
        (push (decode-resource-record) additional-records))
      (values id flags
              (reverse questions)
              (reverse answers)
              (reverse authority-records)
              (reverse additional-records)))))

(defun resolve-address (domain)
  (dotimes (i 3) ; UDP is unreliable.
    (loop
       for (server . tag) in *dns-servers*
       for id = (random (expt 2 16))
       do (mezzano.network.udp:with-udp-connection (conn server +dns-port+)
            (sys.net:send (build-dns-packet id +dns-standard-query+
                                            :questions `((,domain :a :in)))
                          conn)
            (let ((response (sys.net:receive conn 10)))
              (when response
                (multiple-value-bind (rx-id flags questions answers authority-rrs additional-rrs)
                    (decode-dns-packet response)
                  (when (eql rx-id id)
                    (dolist (a answers)
                      (when (eql (second a) :a)
                        (return-from resolve-address
                          (mezzano.network.ip:make-ipv4-address (fifth a)))))))))))))
