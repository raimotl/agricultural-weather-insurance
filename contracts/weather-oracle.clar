;; weather-oracle
;; Oracle contract for validating and managing weather data feeds for insurance claims

;; --------------------------------------------
;; Constants and Error Codes
;; --------------------------------------------
(define-constant ERR-NOT-AUTHORIZED (err u200))
(define-constant ERR-INVALID-DATA-SOURCE (err u201))
(define-constant ERR-DATA-TOO-OLD (err u202))
(define-constant ERR-CONFIDENCE-TOO-LOW (err u203))
(define-constant ERR-DUPLICATE-SUBMISSION (err u204))
(define-constant ERR-ORACLE-SUSPENDED (err u205))
(define-constant ERR-INVALID-LOCATION (err u206))
(define-constant ERR-DATA-OUT_OF-RANGE (err u207))

;; Data type constants
(define-constant DATA-TEMPERATURE u1)
(define-constant DATA-PRECIPITATION u2)
(define-constant DATA-HUMIDITY u3)
(define-constant DATA-WIND-SPEED u4)
(define-constant DATA-SOIL-MOISTURE u5)
(define-constant DATA-UV-INDEX u6)

;; Oracle status constants
(define-constant ORACLE-ACTIVE u1)
(define-constant ORACLE-SUSPENDED u2)
(define-constant ORACLE-INACTIVE u3)

;; Data validation status
(define-constant VALIDATION-PENDING u0)
(define-constant VALIDATION-APPROVED u1)
(define-constant VALIDATION-REJECTED u2)

;; --------------------------------------------
;; Data Variables
;; --------------------------------------------
(define-data-var contract-owner principal tx-sender)
(define-data-var system-active bool true)
(define-data-var min-confidence-threshold uint u70)
(define-data-var max-data-age uint u144) ;; 1 day in blocks
(define-data-var min-consensus-sources uint u3)

;; Oracle management
(define-data-var next-oracle-id uint u1)
(define-data-var active-oracles-count uint u0)
(define-data-var next-submission-id uint u1)

;; Data quality metrics
(define-data-var total-submissions uint u0)
(define-data-var approved-submissions uint u0)
(define-data-var rejected-submissions uint u0)

;; --------------------------------------------
;; Data Maps
;; --------------------------------------------

;; Registered oracle providers
(define-map oracle-providers
  { oracle-id: uint }
  { provider: principal,
    name: (string-ascii 50),
    data-types: (list 10 uint),
    reputation-score: uint,
    total-submissions: uint,
    approved-submissions: uint,
    status: uint,
    registration-block: uint,
    last-activity: uint })

;; Weather data submissions from oracles
(define-map weather-submissions
  { submission-id: uint }
  { oracle-id: uint,
    location-lat: int,
    location-lon: int,
    data-type: uint,
    value: int,
    confidence: uint,
    data-source: (string-ascii 50),
    submission-block: uint,
    validation-status: uint,
    consensus-count: uint })

;; Aggregated consensus weather data
(define-map consensus-data
  { location-lat: int, location-lon: int, data-type: uint, block-window: uint }
  { consensus-value: int,
    participating-oracles: uint,
    confidence-average: uint,
    variance: uint,
    last-updated: uint,
    validation-complete: bool })

;; Oracle performance tracking
(define-map oracle-performance
  { oracle-id: uint, period: uint }
  { accuracy-rate: uint,
    response-time-avg: uint,
    data-quality-score: uint,
    penalties: uint,
    rewards: uint })

;; Data validation results
(define-map validation-results
  { submission-id: uint }
  { validated-by: principal,
    validation-block: uint,
    validation-decision: uint,
    validation-notes: (string-ascii 200),
    consensus-deviation: uint })

;; Geographic coverage tracking
(define-map coverage-areas
  { lat-zone: int, lon-zone: int }
  { active-oracles: uint,
    data-freshness: uint,
    coverage-quality: uint,
    last-update: uint })

;; --------------------------------------------
;; Utility Functions
;; --------------------------------------------
(define-private (is-contract-owner)
  (is-eq tx-sender (var-get contract-owner)))

(define-private (assert-owner)
  (if (is-contract-owner)
      (ok true)
      ERR-NOT-AUTHORIZED))

(define-private (assert-system-active)
  (if (var-get system-active)
      (ok true)
      ERR-NOT-AUTHORIZED))

(define-private (get-current-block)
  block-height)

(define-private (is-valid-location (lat int) (lon int))
  (and (and (>= lat -900000) (<= lat 900000))
       (and (>= lon -1800000) (<= lon 1800000))))

(define-private (is-valid-data-type (data-type uint))
  (and (>= data-type DATA-TEMPERATURE) (<= data-type DATA-UV-INDEX)))

(define-private (calculate-zone (coordinate int))
  (/ coordinate 100000)) ;; 1 degree zones

;; --------------------------------------------
;; Oracle Registration and Management
;; --------------------------------------------
(define-public (register-oracle (name (string-ascii 50)) (data-types (list 10 uint)))
  (begin
    (unwrap! (assert-system-active) ERR-NOT-AUTHORIZED)
    
    (let ((oracle-id (var-get next-oracle-id))
          (current-block (get-current-block)))
      
      ;; Register the oracle
      (map-set oracle-providers { oracle-id: oracle-id }
        { provider: tx-sender,
          name: name,
          data-types: data-types,
          reputation-score: u100,
          total-submissions: u0,
          approved-submissions: u0,
          status: ORACLE-ACTIVE,
          registration-block: current-block,
          last-activity: current-block })
      
      ;; Initialize performance tracking
      (map-set oracle-performance { oracle-id: oracle-id, period: u0 }
        { accuracy-rate: u100,
          response-time-avg: u0,
          data-quality-score: u100,
          penalties: u0,
          rewards: u0 })
      
      ;; Update counters
      (var-set next-oracle-id (+ oracle-id u1))
      (var-set active-oracles-count (+ (var-get active-oracles-count) u1))
      
      (ok oracle-id))))

(define-public (update-oracle-status (oracle-id uint) (new-status uint))
  (begin
    (unwrap! (assert-owner) ERR-NOT-AUTHORIZED)
    
    (match (map-get? oracle-providers { oracle-id: oracle-id })
      oracle-data
        (begin
          (map-set oracle-providers { oracle-id: oracle-id }
            (merge oracle-data { status: new-status, last-activity: (get-current-block) }))
          
          ;; Update active count
          (if (and (is-eq (get status oracle-data) ORACLE-ACTIVE) (not (is-eq new-status ORACLE-ACTIVE)))
              (var-set active-oracles-count (- (var-get active-oracles-count) u1))
              (if (and (not (is-eq (get status oracle-data) ORACLE-ACTIVE)) (is-eq new-status ORACLE-ACTIVE))
                  (var-set active-oracles-count (+ (var-get active-oracles-count) u1))
                  true))
          (ok true))
      ERR-INVALID-DATA-SOURCE)))

;; --------------------------------------------
;; Weather Data Submission
;; --------------------------------------------
(define-public (submit-weather-data 
    (oracle-id uint) (lat int) (lon int) (data-type uint) (value int) 
    (confidence uint) (data-source (string-ascii 50)))
  (begin
    (unwrap! (assert-system-active) ERR-NOT-AUTHORIZED)
    
    ;; Validate oracle authorization
    (match (map-get? oracle-providers { oracle-id: oracle-id })
      oracle-data
        (begin
          (asserts! (is-eq tx-sender (get provider oracle-data)) ERR-NOT-AUTHORIZED)
          (asserts! (is-eq (get status oracle-data) ORACLE-ACTIVE) ERR-ORACLE-SUSPENDED)
          (asserts! (is-valid-location lat lon) ERR-INVALID-LOCATION)
          (asserts! (is-valid-data-type data-type) ERR-INVALID-DATA-SOURCE)
          (asserts! (>= confidence (var-get min-confidence-threshold)) ERR-CONFIDENCE-TOO-LOW)
          
          (let ((submission-id (var-get next-submission-id))
                (current-block (get-current-block)))
            
            ;; Create submission record
            (map-set weather-submissions { submission-id: submission-id }
              { oracle-id: oracle-id,
                location-lat: lat,
                location-lon: lon,
                data-type: data-type,
                value: value,
                confidence: confidence,
                data-source: data-source,
                submission-block: current-block,
                validation-status: VALIDATION-PENDING,
                consensus-count: u1 })
            
            ;; Update oracle activity
            (map-set oracle-providers { oracle-id: oracle-id }
              (merge oracle-data 
                { total-submissions: (+ (get total-submissions oracle-data) u1),
                  last-activity: current-block }))
            
            ;; Update global counters
            (var-set next-submission-id (+ submission-id u1))
            (var-set total-submissions (+ (var-get total-submissions) u1))
            
            ;; Process for consensus
            (unwrap! (update-consensus-data lat lon data-type value confidence current-block) (err u999))
            
            ;; Update coverage tracking
            (unwrap! (update-coverage-area lat lon) (err u999))
            
            (ok submission-id)))
      ERR-INVALID-DATA-SOURCE)))

;; --------------------------------------------
;; Data Consensus and Validation
;; --------------------------------------------
(define-private (update-consensus-data (lat int) (lon int) (data-type uint) (value int) (confidence uint) (block uint))
  (let ((block-window (/ block u144)) ;; Daily windows
        (lat-zone (calculate-zone lat))
        (lon-zone (calculate-zone lon)))
    
    (match (map-get? consensus-data { location-lat: lat-zone, location-lon: lon-zone, data-type: data-type, block-window: block-window })
      existing-consensus
        ;; Update existing consensus
        (let ((new-oracle-count (+ (get participating-oracles existing-consensus) u1))
              (current-total (* (get consensus-value existing-consensus) (to-int (get participating-oracles existing-consensus))))
              (new-consensus (/ (+ current-total value) (to-int new-oracle-count)))
              (new-confidence-avg (/ (+ (* (get confidence-average existing-consensus) (get participating-oracles existing-consensus)) confidence) new-oracle-count)))
          
          (map-set consensus-data { location-lat: lat-zone, location-lon: lon-zone, data-type: data-type, block-window: block-window }
            { consensus-value: new-consensus,
              participating-oracles: new-oracle-count,
              confidence-average: new-confidence-avg,
              variance: (calculate-variance value new-consensus),
              last-updated: block,
              validation-complete: (>= new-oracle-count (var-get min-consensus-sources)) })
          (ok true))
      
      ;; Create new consensus entry
      (begin
        (map-set consensus-data { location-lat: lat-zone, location-lon: lon-zone, data-type: data-type, block-window: block-window }
          { consensus-value: value,
            participating-oracles: u1,
            confidence-average: confidence,
            variance: u0,
            last-updated: block,
            validation-complete: false })
        (ok true)))))

(define-private (calculate-variance (value int) (consensus int))
  (let ((diff (if (>= value consensus) (- value consensus) (- consensus value))))
    (to-uint diff)))

(define-private (update-coverage-area (lat int) (lon int))
  (let ((lat-zone (calculate-zone lat))
        (lon-zone (calculate-zone lon))
        (current-block (get-current-block)))
    
    (match (map-get? coverage-areas { lat-zone: lat-zone, lon-zone: lon-zone })
      existing-coverage
        (map-set coverage-areas { lat-zone: lat-zone, lon-zone: lon-zone }
          (merge existing-coverage { data-freshness: current-block, last-update: current-block }))
      
      (map-set coverage-areas { lat-zone: lat-zone, lon-zone: lon-zone }
        { active-oracles: u1,
          data-freshness: current-block,
          coverage-quality: u100,
          last-update: current-block }))
    (ok true)))

;; --------------------------------------------
;; Data Validation and Quality Control
;; --------------------------------------------
(define-public (validate-submission (submission-id uint) (validation-decision uint) (notes (string-ascii 200)))
  (begin
    (unwrap! (assert-owner) ERR-NOT-AUTHORIZED)
    
    (match (map-get? weather-submissions { submission-id: submission-id })
      submission-data
        (begin
          (asserts! (is-eq (get validation-status submission-data) VALIDATION-PENDING) ERR-DUPLICATE-SUBMISSION)
          
          ;; Update submission validation status
          (map-set weather-submissions { submission-id: submission-id }
            (merge submission-data { validation-status: validation-decision }))
          
          ;; Record validation result
          (map-set validation-results { submission-id: submission-id }
            { validated-by: tx-sender,
              validation-block: (get-current-block),
              validation-decision: validation-decision,
              validation-notes: notes,
              consensus-deviation: u0 })
          
          ;; Update oracle reputation based on validation
          (unwrap! (update-oracle-reputation (get oracle-id submission-data) validation-decision) (err u999))
          
          ;; Update global counters
          (if (is-eq validation-decision VALIDATION-APPROVED)
              (var-set approved-submissions (+ (var-get approved-submissions) u1))
              (var-set rejected-submissions (+ (var-get rejected-submissions) u1)))
          
          (ok true))
      ERR-INVALID-DATA-SOURCE)))

(define-private (update-oracle-reputation (oracle-id uint) (validation-result uint))
  (match (map-get? oracle-providers { oracle-id: oracle-id })
    oracle-data
      (let ((reputation-change (if (is-eq validation-result VALIDATION-APPROVED) u1 u0))
            (reputation-adj (if (is-eq validation-result VALIDATION-APPROVED) 
                               (+ (get reputation-score oracle-data) u1)
                               (if (>= (get reputation-score oracle-data) u5)
                                  (- (get reputation-score oracle-data) u5)
                                  u0)))
            (new-reputation reputation-adj)
            (clamped-reputation (if (> new-reputation u200) u200 (if (< new-reputation u0) u0 new-reputation))))
        
        (map-set oracle-providers { oracle-id: oracle-id }
          (merge oracle-data 
            { reputation-score: clamped-reputation,
              approved-submissions: (if (is-eq validation-result VALIDATION-APPROVED)
                                      (+ (get approved-submissions oracle-data) u1)
                                      (get approved-submissions oracle-data)) }))
        (ok true))
    ERR-INVALID-DATA-SOURCE))

;; --------------------------------------------
;; Data Access and Queries
;; --------------------------------------------
(define-read-only (get-oracle-info (oracle-id uint))
  (map-get? oracle-providers { oracle-id: oracle-id }))

(define-read-only (get-submission-info (submission-id uint))
  (map-get? weather-submissions { submission-id: submission-id }))

(define-read-only (get-consensus-data (lat int) (lon int) (data-type uint) (block-window uint))
  (let ((lat-zone (calculate-zone lat))
        (lon-zone (calculate-zone lon)))
    (map-get? consensus-data { location-lat: lat-zone, location-lon: lon-zone, data-type: data-type, block-window: block-window })))

(define-read-only (get-oracle-performance (oracle-id uint) (period uint))
  (map-get? oracle-performance { oracle-id: oracle-id, period: period }))

(define-read-only (get-coverage-area (lat-zone int) (lon-zone int))
  (map-get? coverage-areas { lat-zone: lat-zone, lon-zone: lon-zone }))

(define-read-only (get-system-stats)
  { active-oracles: (var-get active-oracles-count),
    total-submissions: (var-get total-submissions),
    approved-submissions: (var-get approved-submissions),
    rejected-submissions: (var-get rejected-submissions),
    system-active: (var-get system-active),
    approval-rate: (if (> (var-get total-submissions) u0)
                     (/ (* (var-get approved-submissions) u100) (var-get total-submissions))
                     u0) })

;; --------------------------------------------
;; Administrative Functions
;; --------------------------------------------
(define-public (set-system-active (active bool))
  (begin
    (unwrap! (assert-owner) ERR-NOT-AUTHORIZED)
    (var-set system-active active)
    (ok active)))

(define-public (update-validation-parameters (min-confidence uint) (max-age uint) (min-consensus uint))
  (begin
    (unwrap! (assert-owner) ERR-NOT-AUTHORIZED)
    (var-set min-confidence-threshold min-confidence)
    (var-set max-data-age max-age)
    (var-set min-consensus-sources min-consensus)
    (ok true)))

(define-public (penalize-oracle (oracle-id uint) (penalty-amount uint) (reason (string-ascii 100)))
  (begin
    (unwrap! (assert-owner) ERR-NOT-AUTHORIZED)
    
    (match (map-get? oracle-providers { oracle-id: oracle-id })
      oracle-data
        (let ((new-reputation (if (>= (get reputation-score oracle-data) penalty-amount)
                                 (- (get reputation-score oracle-data) penalty-amount)
                                 u0)))
          (map-set oracle-providers { oracle-id: oracle-id }
            (merge oracle-data { reputation-score: new-reputation }))
          (ok true))
      ERR-INVALID-DATA-SOURCE)))

;; --------------------------------------------
;; Data Quality Analysis
;; --------------------------------------------
(define-read-only (analyze-data-quality (lat int) (lon int) (data-type uint) (time-window uint))
  (let ((lat-zone (calculate-zone lat))
        (lon-zone (calculate-zone lon))
        (current-block (get-current-block)))
    
    (match (map-get? consensus-data { location-lat: lat-zone, location-lon: lon-zone, data-type: data-type, block-window: time-window })
      consensus
        { data-available: true,
          participating-oracles: (get participating-oracles consensus),
          confidence: (get confidence-average consensus),
          variance: (get variance consensus),
          data-age: (- current-block (get last-updated consensus)),
          consensus-complete: (get validation-complete consensus) }
      
      { data-available: false,
        participating-oracles: u0,
        confidence: u0,
        variance: u0,
        data-age: u999999,
        consensus-complete: false })))

;; --------------------------------------------
;; Emergency Functions
;; --------------------------------------------
(define-public (emergency-suspend-oracle (oracle-id uint))
  (begin
    (if (or (is-contract-owner) 
            (> (get-oracle-reputation-score oracle-id) u200)) ;; High reputation oracles can report issues
        (update-oracle-status oracle-id ORACLE-SUSPENDED)
        ERR-NOT-AUTHORIZED)))

(define-private (get-oracle-reputation-score (oracle-id uint))
  (match (map-get? oracle-providers { oracle-id: oracle-id })
    oracle-data (get reputation-score oracle-data)
    u0))

;; --------------------------------------------
;; Initialization
;; --------------------------------------------
(define-public (initialize-oracle-system)
  (begin
    (if (is-eq tx-sender (var-get contract-owner))
        (begin
          (var-set system-active true)
          (ok true))
        ERR-NOT-AUTHORIZED)))