;; weather-crop-insurance
;; Parametric crop insurance contract with weather-based triggers and automatic payouts

;; --------------------------------------------
;; Constants and Error Codes
;; --------------------------------------------
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-POLICY-NOT-FOUND (err u101))
(define-constant ERR-ALREADY-CLAIMED (err u102))
(define-constant ERR-POLICY-EXPIRED (err u103))
(define-constant ERR-POLICY-NOT-ACTIVE (err u104))
(define-constant ERR-INSUFFICIENT-PREMIUM (err u105))
(define-constant ERR-INVALID-COORDINATES (err u106))
(define-constant ERR-INVALID-CROP-TYPE (err u107))
(define-constant ERR-COVERAGE-EXCEEDED (err u108))
(define-constant ERR-WEATHER-DATA-STALE (err u109))
(define-constant ERR-PAYOUT-FAILED (err u110))

;; Policy status constants
(define-constant STATUS-PENDING u0)
(define-constant STATUS-ACTIVE u1)
(define-constant STATUS-EXPIRED u2)
(define-constant STATUS-CLAIMED u3)
(define-constant STATUS-CANCELLED u4)

;; Crop type constants
(define-constant CROP-CORN u1)
(define-constant CROP-WHEAT u2)
(define-constant CROP-RICE u3)
(define-constant CROP-SOYBEANS u4)
(define-constant CROP-COTTON u5)

;; Weather trigger types
(define-constant TRIGGER-DROUGHT u1)
(define-constant TRIGGER-FLOOD u2)
(define-constant TRIGGER-FROST u3)
(define-constant TRIGGER-HAIL u4)

;; --------------------------------------------
;; Data Variables
;; --------------------------------------------
(define-data-var contract-owner principal tx-sender)
(define-data-var weather-oracle principal tx-sender)
(define-data-var system-paused bool false)

;; Financial variables
(define-data-var total-reserves uint u0)
(define-data-var total-premiums-collected uint u0)
(define-data-var total-payouts-made uint u0)

;; Policy management
(define-data-var next-policy-id uint u1)
(define-data-var active-policies-count uint u0)
(define-data-var max-policy-coverage uint u100000000)
(define-data-var min-policy-coverage uint u1000000)

;; Risk parameters
(define-data-var base-premium-rate uint u5)
(define-data-var weather-data-expiry uint u144)

;; --------------------------------------------
;; Data Maps
;; --------------------------------------------

;; Core policy structure
(define-map policies
  { policy-id: uint }
  { farmer: principal,
    farm-latitude: int,
    farm-longitude: int,
    crop-type: uint,
    coverage-amount: uint,
    premium-paid: uint,
    start-block: uint,
    end-block: uint,
    status: uint,
    claim-amount: uint,
    last-updated: uint })

;; Weather trigger conditions for policies
(define-map weather-triggers
  { policy-id: uint }
  { trigger-type: uint,
    threshold-low: int,
    threshold-high: int,
    measurement-period: uint,
    max-payout-ratio: uint })

;; Weather data storage
(define-map weather-data
  { location-lat: int, location-lon: int, data-type: uint }
  { value: int,
    timestamp: uint,
    data-source: (string-ascii 50),
    confidence: uint,
    validated: bool })

;; Claims processing
(define-map claims
  { policy-id: uint }
  { claim-block: uint,
    weather-triggered: bool,
    calculated-payout: uint,
    final-payout: uint,
    processing-status: uint,
    processed-block: uint })

;; Farmer profiles
(define-map farmer-profiles
  { farmer: principal }
  { total-policies: uint,
    active-policies: uint,
    total-claims: uint,
    reputation-score: uint,
    registration-block: uint })

;; --------------------------------------------
;; Utility Functions
;; --------------------------------------------
(define-private (is-contract-owner)
  (is-eq tx-sender (var-get contract-owner)))

(define-private (is-authorized-oracle)
  (is-eq tx-sender (var-get weather-oracle)))

(define-private (assert-owner)
  (if (is-contract-owner)
      (ok true)
      ERR-NOT-AUTHORIZED))

(define-private (assert-not-paused)
  (if (var-get system-paused)
      ERR-NOT-AUTHORIZED
      (ok true)))

(define-private (get-current-block)
  block-height)

(define-private (is-valid-coordinates (lat int) (lon int))
  (and (and (>= lat -900000) (<= lat 900000))
       (and (>= lon -1800000) (<= lon 1800000))))

(define-private (is-valid-crop-type (crop-type uint))
  (and (>= crop-type CROP-CORN) (<= crop-type CROP-COTTON)))

;; --------------------------------------------
;; Administrative Functions
;; --------------------------------------------
(define-public (set-paused (paused bool))
  (begin
    (unwrap! (assert-owner) ERR-NOT-AUTHORIZED)
    (var-set system-paused paused)
    (ok paused)))

(define-public (set-weather-oracle (new-oracle principal))
  (begin
    (unwrap! (assert-owner) ERR-NOT-AUTHORIZED)
    (var-set weather-oracle new-oracle)
    (ok true)))

(define-public (update-system-parameters (new-base-rate uint) (new-max-coverage uint))
  (begin
    (unwrap! (assert-owner) ERR-NOT-AUTHORIZED)
    (var-set base-premium-rate new-base-rate)
    (var-set max-policy-coverage new-max-coverage)
    (ok true)))

;; --------------------------------------------
;; Policy Creation and Management
;; --------------------------------------------
(define-public (create-policy 
    (farm-lat int) (farm-lon int) (crop-type uint) (coverage-amount uint)
    (duration-blocks uint) (trigger-type uint) (threshold-low int) (threshold-high int))
  (begin
    (unwrap! (assert-not-paused) ERR-NOT-AUTHORIZED)
    
    ;; Input validation
    (asserts! (is-valid-coordinates farm-lat farm-lon) ERR-INVALID-COORDINATES)
    (asserts! (is-valid-crop-type crop-type) ERR-INVALID-CROP-TYPE)
    (asserts! (and (>= coverage-amount (var-get min-policy-coverage))
                   (<= coverage-amount (var-get max-policy-coverage))) ERR-COVERAGE-EXCEEDED)
    
    (let ((policy-id (var-get next-policy-id))
          (current-block (get-current-block))
          (end-block (+ current-block duration-blocks))
          (premium (calculate-premium coverage-amount duration-blocks)))
      
      ;; Create the policy
      (map-set policies { policy-id: policy-id }
        { farmer: tx-sender,
          farm-latitude: farm-lat,
          farm-longitude: farm-lon,
          crop-type: crop-type,
          coverage-amount: coverage-amount,
          premium-paid: premium,
          start-block: current-block,
          end-block: end-block,
          status: STATUS-ACTIVE,
          claim-amount: u0,
          last-updated: current-block })
      
      ;; Set weather triggers
      (map-set weather-triggers { policy-id: policy-id }
        { trigger-type: trigger-type,
          threshold-low: threshold-low,
          threshold-high: threshold-high,
          measurement-period: duration-blocks,
          max-payout-ratio: u100 })
      
      ;; Update counters and farmer profile
      (var-set next-policy-id (+ policy-id u1))
      (var-set active-policies-count (+ (var-get active-policies-count) u1))
      (var-set total-premiums-collected (+ (var-get total-premiums-collected) premium))
      
      ;; Update farmer profile
      (let ((profile (default-to 
              { total-policies: u0, active-policies: u0, total-claims: u0, 
                reputation-score: u100, registration-block: current-block }
              (map-get? farmer-profiles { farmer: tx-sender }))))
        (map-set farmer-profiles { farmer: tx-sender }
          { total-policies: (+ (get total-policies profile) u1),
            active-policies: (+ (get active-policies profile) u1),
            total-claims: (get total-claims profile),
            reputation-score: (get reputation-score profile),
            registration-block: (get registration-block profile) }))
      
      (ok policy-id))))

(define-private (calculate-premium (coverage uint) (duration uint))
  (let ((base-rate (var-get base-premium-rate))
        (duration-factor (/ duration u1008)))
    (/ (* (* coverage base-rate) (+ u100 duration-factor)) u10000)))

;; --------------------------------------------
;; Weather Data Integration
;; --------------------------------------------
(define-public (submit-weather-data 
    (lat int) (lon int) (data-type uint) (value int) (source (string-ascii 50)) (confidence uint))
  (begin
    (asserts! (is-authorized-oracle) ERR-NOT-AUTHORIZED)
    (let ((current-block (get-current-block)))
      (map-set weather-data { location-lat: lat, location-lon: lon, data-type: data-type }
        { value: value,
          timestamp: current-block,
          data-source: source,
          confidence: confidence,
          validated: true })
      
      ;; Trigger automatic claim processing for nearby policies
      (unwrap! (process-weather-triggers lat lon data-type value) (err u999))
      (ok true))))

(define-private (process-weather-triggers (lat int) (lon int) (data-type uint) (value int))
  ;; Simplified implementation - would check nearby policies in production
  (ok true))

;; --------------------------------------------
;; Claims Processing
;; --------------------------------------------
(define-public (file-claim (policy-id uint) (claim-reason (string-ascii 200)))
  (begin
    (unwrap! (assert-not-paused) ERR-NOT-AUTHORIZED)
    (match (map-get? policies { policy-id: policy-id })
      policy-data
        (begin
          (asserts! (is-eq tx-sender (get farmer policy-data)) ERR-NOT-AUTHORIZED)
          (asserts! (is-eq (get status policy-data) STATUS-ACTIVE) ERR-POLICY-NOT-ACTIVE)
          (asserts! (is-none (map-get? claims { policy-id: policy-id })) ERR-ALREADY-CLAIMED)
          
          (let ((current-block (get-current-block)))
            ;; Create claim record
            (map-set claims { policy-id: policy-id }
              { claim-block: current-block,
                weather-triggered: false,
                calculated-payout: u0,
                final-payout: u0,
                processing-status: STATUS-PENDING,
                processed-block: u0 })
            
            ;; Evaluate claim automatically
            (unwrap! (evaluate-claim policy-id) (err u999))
            (ok policy-id)))
      ERR-POLICY-NOT-FOUND)))

(define-private (evaluate-claim (policy-id uint))
  (match (map-get? policies { policy-id: policy-id })
    policy-data
      (match (map-get? weather-triggers { policy-id: policy-id })
        trigger-data
          (let ((weather-triggered (check-weather-triggers policy-id))
                (payout-amount (if weather-triggered
                                  (calculate-payout policy-id u75)
                                  u0)))
            
            ;; Update claim with evaluation results
            (match (map-get? claims { policy-id: policy-id })
              claim-data
                (begin
                  (map-set claims { policy-id: policy-id }
                    { claim-block: (get claim-block claim-data),
                      weather-triggered: weather-triggered,
                      calculated-payout: payout-amount,
                      final-payout: payout-amount,
                      processing-status: (if (> payout-amount u0) STATUS-ACTIVE STATUS-EXPIRED),
                      processed-block: (get-current-block) })
                  
                  ;; Execute payout if approved
                  (if (> payout-amount u0)
                      (execute-payout policy-id payout-amount)
                      (ok true)))
              ERR-ALREADY-CLAIMED))
        ERR-POLICY-NOT-FOUND)
    ERR-POLICY-NOT-FOUND))

(define-private (check-weather-triggers (policy-id uint))
  ;; Simplified weather trigger evaluation
  true)

(define-private (calculate-payout (policy-id uint) (severity uint))
  (match (map-get? policies { policy-id: policy-id })
    policy-data
      (match (map-get? weather-triggers { policy-id: policy-id })
        trigger-data
          (let ((coverage (get coverage-amount policy-data))
                (max-payout-ratio (get max-payout-ratio trigger-data))
                (severity-factor (if (> severity u100) u100 severity)))
            (/ (* (* coverage max-payout-ratio) severity-factor) u10000))
        u0)
    u0))

(define-private (execute-payout (policy-id uint) (payout-amount uint))
  (match (map-get? policies { policy-id: policy-id })
    policy-data
      (begin
        ;; Update policy status
        (map-set policies { policy-id: policy-id }
          (merge policy-data { status: STATUS-CLAIMED, claim-amount: payout-amount }))
        
        ;; Update system counters
        (var-set total-payouts-made (+ (var-get total-payouts-made) payout-amount))
        (var-set active-policies-count (- (var-get active-policies-count) u1))
        
        ;; Update farmer profile
        (unwrap! (match (map-get? farmer-profiles { farmer: (get farmer policy-data) })
          profile
            (begin
              (map-set farmer-profiles { farmer: (get farmer policy-data) }
                (merge profile 
                  { active-policies: (- (get active-policies profile) u1),
                    total-claims: (+ (get total-claims profile) u1) }))
              (ok true))
          (ok true)) (err u999))
        
        (ok true))
    ERR-POLICY-NOT-FOUND))

;; --------------------------------------------
;; Read-Only Functions
;; --------------------------------------------
(define-read-only (get-policy (policy-id uint))
  (map-get? policies { policy-id: policy-id }))

(define-read-only (get-weather-triggers (policy-id uint))
  (map-get? weather-triggers { policy-id: policy-id }))

(define-read-only (get-weather-data (lat int) (lon int) (data-type uint))
  (map-get? weather-data { location-lat: lat, location-lon: lon, data-type: data-type }))

(define-read-only (get-claim (policy-id uint))
  (map-get? claims { policy-id: policy-id }))

(define-read-only (get-farmer-profile (farmer principal))
  (map-get? farmer-profiles { farmer: farmer }))

(define-read-only (get-system-stats)
  { total-reserves: (var-get total-reserves),
    total-premiums: (var-get total-premiums-collected),
    total-payouts: (var-get total-payouts-made),
    active-policies: (var-get active-policies-count),
    system-paused: (var-get system-paused) })

;; --------------------------------------------
;; Reserve Management
;; --------------------------------------------
(define-public (add-reserves (amount uint))
  (begin
    (unwrap! (assert-owner) ERR-NOT-AUTHORIZED)
    (var-set total-reserves (+ (var-get total-reserves) amount))
    (ok true)))

(define-read-only (check-reserve-adequacy)
  (let ((required-reserves (* (var-get total-premiums-collected) u200))
        (current-reserves (var-get total-reserves)))
    { adequate: (>= (* current-reserves u100) required-reserves),
      ratio: (if (> (var-get total-premiums-collected) u0)
                (/ (* current-reserves u100) (var-get total-premiums-collected))
                u0) }))

;; --------------------------------------------
;; Emergency Functions
;; --------------------------------------------
(define-public (emergency-pause)
  (begin
    (if (or (is-contract-owner) (is-authorized-oracle))
        (begin
          (var-set system-paused true)
          (ok true))
        ERR-NOT-AUTHORIZED)))

(define-public (emergency-payout (policy-id uint) (override-amount uint))
  (begin
    (unwrap! (assert-owner) ERR-NOT-AUTHORIZED)
    (execute-payout policy-id override-amount)))

;; --------------------------------------------
;; Initialization
;; --------------------------------------------
(define-public (initialize-contract)
  (begin
    (if (is-eq tx-sender (var-get contract-owner))
        (ok true)
        ERR-NOT-AUTHORIZED)))