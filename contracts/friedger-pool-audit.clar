;; bitcoin reward address of the pool
(define-constant pool-reward-addr-hash 0xc70e1ca5a5ef633fe5464821ca421c173997f388)
;;(define-constant pool-pubscriptkey (concat (concat 0xa914 pool-reward-addr-hash) 0x87))
(define-constant pool-pubscriptkey (concat (concat 0x76a914 pool-reward-addr-hash) 0x88ac))

;; store reward txs and their value per block (from up to 100 miners per block)
(define-map reward-txs
  uint (list 100 {txid: (buff 1024), value: uint}))

(define-map rewards-per-cycle uint uint)

;; Backport of .pox's burn-height-to-reward-cycle
(define-private (burn-height-to-reward-cycle (height uint))
    (let (
        (pox-info (unwrap-panic (contract-call? 'ST000000000000000000002AMW42H.pox get-pox-info)))
    )
    (/ (- height (get first-burnchain-block-height pox-info)) (get reward-cycle-length pox-info)))
)

(define-private (find-pool-out (entry {scriptPubKey: (buff 128), value: uint}) (result (optional {scriptPubKey: (buff 128), value: uint})))
  (if (is-eq (get scriptPubKey entry) pool-pubscriptkey)
    (some entry)
    result))

(define-read-only (get-tx-value-for-pool-2 (tx {
    version: uint,
    ins: (list 8
      {outpoint: {hash: (buff 32), index: uint}, scriptSig: (buff 256), sequence: uint}),
    outs: (list 8
      {value: uint, scriptPubKey: (buff 128)}),
    locktime: uint}))
    (ok (fold find-pool-out (get outs tx) none)))

(define-read-only (get-tx-value-for-pool (tx (buff 1024)))
  (let ((transaction (unwrap! (contract-call? .clarity-bitcoin parse-tx tx) ERR_FAILED_TO_PARSE_TX)))
    (ok (fold find-pool-out (get outs transaction) none))))

(define-read-only (oracle-get-price-stx-btc (height uint))
  (default-to u0 (get amount (at-block (unwrap-panic (get-block-info? id-header-hash height)) (contract-call? .oracle get-price "artifix-binance" "STX-BTC")))))

(define-private (map-add-tx (height uint) (tx (buff 1024)) (pool-out-value uint))
  (let ((entry {txid: (contract-call? .clarity-bitcoin get-txid tx), value: pool-out-value})
    (price (oracle-get-price-stx-btc height))
    (cycle (burn-height-to-reward-cycle height)))
    (map-set rewards-per-cycle cycle (+ (/ pool-out-value price) (default-to u0 (map-get? rewards-per-cycle cycle))))
    (match (map-get? reward-txs height)
      txs (ok (map-set reward-txs height (unwrap! (as-max-len? (append txs entry) u100) ERR_TOO_MANY_TXS)))
      (ok (map-insert reward-txs height (list entry))))))

;; any user can submit a tx that contains payments into the pool's address
;; the value of the tx is added to the block
(define-public (submit-reward-tx (block { header: (buff 80), height: uint }) (tx (buff 1024)) (proof { tx-index: uint, hashes: (list 12 (buff 32)), tree-depth: uint }))
  (match (contract-call? .clarity-bitcoin was-tx-mined? block tx proof)
    result
      (begin
        (asserts! result ERR_VERIFICATION_FAILED)
        (let ((pool-out (unwrap! (unwrap! (get-tx-value-for-pool tx) ERR_FAILED_TO_PARSE_TX) ERR_TX_NOT_FOR_POOL)))
            ;; add tx value to corresponding cycle
            (match (map-add-tx (get height block) tx (get value pool-out))
              result-map-add (begin
                (asserts! result-map-add ERR_TX_ADD_FAILED)
                (ok true))
              error-map-add (err error-map-add))))
    error (err error)))

(define-read-only (get-rewards (cycle uint))
  (default-to u0 (map-get? rewards-per-cycle cycle)))

(define-read-only (get-pool-pubscriptkey)
  pool-pubscriptkey
)
;; Error handling
(define-constant ERR_FAILED_TO_PARSE_TX (err u1))
(define-constant ERR_VERIFICATION_FAILED (err u2))
(define-constant ERR_INSERT_FAILED (err u3))
(define-constant ERR_TX_NOT_FOR_POOL (err u4))
(define-constant ERR_TOO_MANY_TXS (err u5))
(define-constant ERR_TX_ADD_FAILED (err u6))
