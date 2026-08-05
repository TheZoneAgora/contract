module agent_market::investment_vault {
    use sui::balance::{Self, Balance};
    use sui::object::{Self, UID, ID};
    use sui::coin::{Self, Coin};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::event;
    use sui::clock::{Self, Clock};
    use sui::table::{Self, Table};
    use agent_market::vault_policy;

    /// 오류코드
    const E_NOT_OWNER: u64 = 1;
    const E_NOT_AGORA_AGENT: u64 = 2; // 🔄 개별 Agent → AgoraAgent 전용 권한 오류
    const E_AGORA_AGENT_INACTIVE: u64 = 3; // 🔄 AgoraAgent 중지 상태 오류
    const E_TRADE_LIMIT_EXCEEDED: u64 = 4;
    const E_INSUFFICIENT_BALANCE: u64 = 5;
    const E_EPOCH_TRADE_LIMIT_EXCEEDED: u64 = 6;
    const E_EPOCH_LIMIT_BELOW_SPENT: u64 = 7;
    const E_INVALID_EPOCH_LIMIT: u64 = 8;
    const E_CRYPTO_SELL_LIMIT_EXCEEDED: u64 = 9;
    const E_EPOCH_CRYPTO_SELL_LIMIT_EXCEEDED: u64 = 10;
    const E_INVALID_CRYPTO_SELL_LIMIT: u64 = 11;
    const E_EPOCH_CRYPTO_LIMIT_BELOW_SPENT: u64 = 12;
    const E_ZERO_TRADE_AMOUNT: u64 = 13;
    const E_BUY_DISABLED_IN_REDUCE_ONLY: u64 = 14; // 🆕 REDUCE_ONLY 신규 BUY 차단
    const E_INVALID_EXECUTION_POLICY: u64 = 15;
    const E_POOL_NOT_ALLOWED: u64 = 16;
    const E_DUPLICATE_SIGNAL: u64 = 17;
    const E_DAILY_VOLUME_EXCEEDED: u64 = 18;
    const E_POSITION_LIMIT_EXCEEDED: u64 = 19;
    const E_MAX_LOSS_EXCEEDED: u64 = 20;
    const E_MIN_OUTPUT_NOT_MET: u64 = 21;
    const E_RISK_SCORE_EXCEEDED: u64 = 22; // 🆕 Signal 위험도가 Vault 허용 상한을 초과
    const E_INVALID_RISK_SCORE: u64 = 23; // 🆕 위험도 값이 bps 범위를 벗어남
    const E_INVALID_LOSS_WINDOW: u64 = 24; // 🆕 급락 감시 창 설정이 올바르지 않음
    const E_NOTHING_TO_LIQUIDATE: u64 = 25; // 🆕 청산할 CryptoT 포지션이 없음
    const E_NOTHING_TO_WITHDRAW: u64 = 26; // 🆕 회수할 FiatT 잔액이 없음

    /// 위험도와 편차를 표현하는 bps 분모다.
    const BPS_DENOMINATOR: u64 = 10_000;

    /// AgoraAgent가 신규 포지션과 포지션 축소를 모두 요청할 수 있다.
    const AGORA_STATUS_ACTIVE: u8 = 0; // 🆕 BUY·SELL 허용 상태
    /// 위험을 줄이기 위한 SELL만 요청할 수 있다.
    const AGORA_STATUS_REDUCE_ONLY: u8 = 1; // 🆕 SELL만 허용하는 위험 축소 상태
    /// AgoraAgent의 BUY/SELL 요청을 모두 중지한다.
    const AGORA_STATUS_PAUSED: u8 = 2; // 🆕 BUY·SELL 모두 중지하는 상태

    /// 사용자가 소유권을 유지하면서 AgoraAgent에만 제한된 거래 권한을 주는 투자 금고.
    /// 외부 Signal Provider는 이 객체에 대한 온체인 권한을 갖지 않는다.
    public struct UserVault<phantom FiatT, phantom CryptoT> has key {
        // key가 있음으로 UID 필수
        id: UID,

        /// 최종 출금 권한을 가진 사용자
        owner: address,

        /// 거래를 요청할 수 있는 AgoraAgent 운영 지갑
        agora_agent_operator: address, // 🔄 개별 Agent 주소 → AgoraAgent 단일 운영 주소

        /// ACTIVE, REDUCE_ONLY, PAUSED 중 하나인 AgoraAgent 실행 상태
        agora_agent_status: u8, // 🔄 agent_active bool → 3단계 상태

        /// FiatT로 CryptoT를 매수할 때 한 번에 사용할 수 있는 최대 FiatT 수량
        max_trade_amount: u64,

        /// 한 epoch 동안 매수에 사용할 수 있는 최대 FiatT 누적 수량
        max_epoch_trade_amount: u64,

        /// 현재 spending_epoch에서 매수 요청에 사용한 FiatT 누적 수량
        spent_this_epoch: u64,

        /// CryptoT를 FiatT로 매도할 때 한 번에 사용할 수 있는 최대 CryptoT 수량
        max_crypto_sell_amount: u64,

        /// 한 epoch 동안 매도할 수 있는 최대 CryptoT 누적 수량
        max_epoch_crypto_sell_amount: u64,

        /// 현재 spending_epoch에서 매도 요청한 CryptoT 누적 수량
        spent_crypto_this_epoch: u64,

        /// spent_this_epoch가 속한 Sui epoch
        spending_epoch: u64,

        /// 매수 전용 기준 자산. 예: USDC
        fiat_balance: Balance<FiatT>,

        /// 매도 전용 투자 자산. 예: SUI
        crypto_balance: Balance<CryptoT>,

        /// 첫 실행 MVP에서 허용하는 단일 Pool 주소다. @0x0은 미설정 상태다.
        allowed_pool: address,
        /// UTC 기준 하루 동안 거래할 수 있는 FiatT 환산 누적 한도다.
        max_daily_fiat_volume: u64,
        /// 현재 UTC 날짜에 사용한 FiatT 환산 거래량이다.
        daily_fiat_volume: u64,
        /// daily_fiat_volume이 속한 UTC 날짜 번호다.
        volume_day_utc: u64,
        /// Vault가 보유할 수 있는 CryptoT 최대 수량이다.
        max_position_size: u64,
        /// 누적 실현 손실의 최대 허용 FiatT 금액이다.
        max_loss_amount: u64,
        /// 지금까지 확정된 누적 실현 손실이다.
        realized_loss_amount: u64,
        /// 현재 CryptoT 포지션에 남아 있는 FiatT 취득 원가다.
        cost_basis_fiat: u64,
        /// 거래 허용 시작 시각을 UTC 자정 이후 분 단위로 저장한다.
        trading_start_minute_utc: u64,
        /// 거래 허용 종료 시각을 UTC 자정 이후 분 단위로 저장한다.
        trading_end_minute_utc: u64,
        /// Signal 생성 후 실행할 수 있는 최대 지연 시간이다.
        max_signal_delay_ms: u64,
        /// Signal 가격과 DEX Quote 가격 사이의 최대 허용 편차다.
        max_price_deviation_bps: u64,
        /// 신규 포지션(BUY)을 허용하는 Signal 위험도 상한이다.
        /// SELL에는 적용하지 않는다. 상세 근거는 assert_buy_risk_score_allowed 참고.
        max_risk_score_bps: u64,
        /// 급락을 판정할 때 손실을 합산하는 관찰 창의 길이다.
        loss_window_ms: u64,
        /// 관찰 창 하나에서 허용하는 최대 실현 손실이다. 넘으면 Kill Switch가 발동한다.
        max_window_loss_amount: u64,
        /// 현재 관찰 창에서 누적된 실현 손실이다.
        window_loss_amount: u64,
        /// 현재 관찰 창이 시작된 시각이다.
        window_started_at_ms: u64,
        /// Vault별로 이미 성공한 Signal ID를 저장해 중복 실행을 차단한다.
        executed_signals: Table<vector<u8>, bool>,

        // [DYNAMIC BAG 전환 지점]
        // 나중에 여러 crypto를 지원할 때 crypto_balance 한 필드를
        // AssetKey<CryptoT> -> Balance<CryptoT> Dynamic Field/Bag 정책으로 바꾼다.
        // 그때도 FiatT는 BUY 입력, 허용된 CryptoT는 SELL 입력이라는 역할 검사를 유지한다.

    }

    // 이벤트 구조체
    /// Owner가 보유 CryptoT를 시장가로 전량 청산했음을 알린다.
    public struct EmergencyLiquidated<phantom FiatT, phantom CryptoT> has copy, drop {
        vault_id: ID,
        owner: address,
        crypto_sold: u64,
        fiat_received: u64,
        released_cost_basis: u64,
        realized_loss: u64,
        pool: address,
        executed_at_ms: u64,
    }

    /// Owner가 AgoraAgent를 정지시키고 FiatT 잔액을 회수했음을 알린다.
    public struct EmergencyFiatWithdrawn<phantom FiatT, phantom CryptoT> has copy, drop {
        vault_id: ID,
        owner: address,
        fiat_withdrawn: u64,
        crypto_left_in_vault: u64,
    }

    /// 급락으로 Kill Switch가 발동해 Vault가 자동 정지되었음을 알린다.
    /// Owner의 reactivate_agent 없이는 AgoraAgent가 다시 거래할 수 없다.
    public struct KillSwitchTriggered<phantom FiatT, phantom CryptoT> has copy, drop {
        vault_id: ID,
        window_loss_amount: u64,
        max_window_loss_amount: u64,
        window_started_at_ms: u64,
        triggered_at_ms: u64,
    }

    // 함수 (15개 함수) --------------------------------------

    // 1. vault 생성
    public fun create_vault<FiatT, CryptoT>(
        deposit: Coin<FiatT>, // 사용자가 전달한 기준 자산
        agora_agent_operator: address, // 🔄 Vault에 연결할 AgoraAgent 운영 주소
        max_trade_amount: u64,
        max_epoch_trade_amount: u64,
        max_crypto_sell_amount: u64,
        max_epoch_crypto_sell_amount: u64,
        ctx: &mut TxContext, // 현재 트랜잭션 정보
    ) {
        let owner = tx_context::sender(ctx);
        let fiat_balance = coin::into_balance(deposit);
        let crypto_balance = balance::zero<CryptoT>();
        let current_epoch = tx_context::epoch(ctx);

        let vault = UserVault<FiatT, CryptoT> {
            id: object::new(ctx),
            owner,
            agora_agent_operator, // 🔄 개별 Agent 대신 AgoraAgent 주소 저장
            agora_agent_status: AGORA_STATUS_ACTIVE, // 🆕 생성 시 ACTIVE 상태
            max_trade_amount,
            max_epoch_trade_amount,
            spent_this_epoch: 0,
            max_crypto_sell_amount,
            max_epoch_crypto_sell_amount,
            spent_crypto_this_epoch: 0,
            spending_epoch: current_epoch,
            fiat_balance,
            crypto_balance,
            allowed_pool: @0x0,
            max_daily_fiat_volume: max_epoch_trade_amount,
            daily_fiat_volume: 0,
            volume_day_utc: 0,
            max_position_size: 18_446_744_073_709_551_615,
            max_loss_amount: 18_446_744_073_709_551_615,
            realized_loss_amount: 0,
            cost_basis_fiat: 0,
            trading_start_minute_utc: 0,
            trading_end_minute_utc: 0,
            max_signal_delay_ms: 300_000,
            max_price_deviation_bps: 500,
            // 실행은 allowed_pool이 설정되기 전까지 어차피 차단되므로
            // 생성 시점 기본값은 상한 없음으로 두고 정책 설정에서 확정한다.
            max_risk_score_bps: BPS_DENOMINATOR,
            loss_window_ms: 3_600_000,
            max_window_loss_amount: 18_446_744_073_709_551_615,
            window_loss_amount: 0,
            window_started_at_ms: 0,
            executed_signals: table::new<vector<u8>, bool>(ctx),
        };

        // 생성 할때 검사
        assert!(max_trade_amount > 0, E_INVALID_EPOCH_LIMIT);

        assert!(max_epoch_trade_amount >= max_trade_amount, E_INVALID_EPOCH_LIMIT);

        assert!(max_crypto_sell_amount > 0, E_INVALID_CRYPTO_SELL_LIMIT);

        assert!(
            max_epoch_crypto_sell_amount >= max_crypto_sell_amount,
            E_INVALID_CRYPTO_SELL_LIMIT,
        );

        transfer::share_object(vault);
    }

    // 2. 돈 전송
    public fun withdraw_all_assets<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        ctx: &mut TxContext,
    ){
        // 1. 현재 트랜잭션 요청을 보낸 주소를 가져온다
        let caller = tx_context::sender(ctx);

        // 2. 요청을 보낸 주소가 vault.owner와 같은지 검사한다.
        // 다르면 E_NOT_OWNER 오류로 실행을 중단한다.
        assert!(caller == vault.owner, E_NOT_OWNER);

        // 3. fiat와 crypto 잔액을 각각 전부 꺼낸다.
        let withdrawn_fiat_balance = balance::withdraw_all(&mut vault.fiat_balance);
        let withdrawn_crypto_balance = balance::withdraw_all(&mut vault.crypto_balance);
        vault.cost_basis_fiat = 0;

        // 4. 두 Balance를 각각 같은 타입의 Coin 객체로 변환한다.
        let withdrawn_fiat_coin = coin::from_balance(withdrawn_fiat_balance, ctx);
        let withdrawn_crypto_coin = coin::from_balance(withdrawn_crypto_balance, ctx);

        // 5. fiat와 crypto를 모두 Vault owner 주소로 전송한다.
        transfer::public_transfer(withdrawn_fiat_coin, vault.owner);
        transfer::public_transfer(withdrawn_crypto_coin, vault.owner);


    }

    // 3. AgoraAgent 권한을 완전히 중지한다.
    // 기존 FE 호환을 위해 공개 함수 이름은 유지한다.
    public fun revoke_agent<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        ctx: &TxContext,
    ) {
        // 1. 현재 트랜잭션 요청을 보낸 주소를 가져온다.
        let caller = tx_context::sender(ctx);

        // 2. 요청자가 Vault owner인지 검사한다.
        // owner가 아니면 E_NOT_OWNER 오류로 중단한다.
        assert!(caller == vault.owner, E_NOT_OWNER);

        vault.agora_agent_status = AGORA_STATUS_PAUSED; // 🔄 bool false → PAUSED
    }

    // 4. 호출자가 이 Vault에 연결된 AgoraAgent인지 검사한다.
    fun assert_agora_agent_authorized<FiatT, CryptoT>(
        vault: &UserVault<FiatT, CryptoT>,
        ctx: &TxContext,
    ){
        let caller = tx_context::sender(ctx);
        assert!(
            caller == vault.agora_agent_operator, // 🔄 AgoraAgent 운영 주소만 허용
            E_NOT_AGORA_AGENT, // 🔄 외부 Signal Provider 등 다른 주소 거부
        );
        assert!(
            vault.agora_agent_status != AGORA_STATUS_PAUSED, // 🆕 PAUSED 거래 차단
            E_AGORA_AGENT_INACTIVE, // 🔄 AgoraAgent 중지 오류
        );
    }

    /// 신규 BUY는 ACTIVE 상태에서만 허용한다.
    fun assert_buy_enabled<FiatT, CryptoT>(
        vault: &UserVault<FiatT, CryptoT>,
    ) {
        assert!(
            vault.agora_agent_status == AGORA_STATUS_ACTIVE, // 🆕 BUY는 ACTIVE만 허용
            E_BUY_DISABLED_IN_REDUCE_ONLY, // 🆕 REDUCE_ONLY BUY 거부
        );
    }

    // FiatT 매수 요청의 1회 한도
    fun assert_fiat_buy_amount_allowed<FiatT, CryptoT>(
        vault: &UserVault<FiatT, CryptoT>,
        fiat_amount: u64,
    ) {
        assert!(fiat_amount > 0, E_ZERO_TRADE_AMOUNT);
        assert!(fiat_amount <= vault.max_trade_amount, E_TRADE_LIMIT_EXCEEDED)
    }

    // CryptoT 매도 요청의 1회 한도
    fun assert_crypto_sell_amount_allowed<FiatT, CryptoT>(
        vault: &UserVault<FiatT, CryptoT>,
        crypto_amount: u64,
    ) {
        assert!(crypto_amount > 0, E_ZERO_TRADE_AMOUNT);
        assert!(
            crypto_amount <= vault.max_crypto_sell_amount,
            E_CRYPTO_SELL_LIMIT_EXCEEDED,
        )
    }

    // 6. 추가입금 (vault에 잔액 추가)
    public fun deposit_more<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        deposit: Coin<FiatT>,
        ctx: &TxContext,
    ) {
        // 1. 현재 요청자 주소를 가져온다.
        let caller = tx_context::sender(ctx);

        // 2. 요청자가 Vault owner인지 확인한다.
        assert!(caller == vault.owner, E_NOT_OWNER);

        // 3. Coin<T>를 Balance<T>로 바꾼다.
        let additional_balance = coin::into_balance(deposit);

        // 4. 변환한 Balance를 기존 fiat_balance에 합친다.
        balance::join(&mut vault.fiat_balance, additional_balance);
    }

    // 테스트에서만 crypto_balance를 준비한다.
    // 운영 코드에서는 사용자가 CryptoT를 직접 넣지 못하며,
    // 향후 execute_buy가 성공한 DEX 결과만 crypto_balance에 합쳐야 한다.
    #[test_only]
    public fun deposit_crypto_for_testing<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        deposit: Coin<CryptoT>,
        _ctx: &TxContext,
    ) {
        let additional_balance = coin::into_balance(deposit);
        balance::join(&mut vault.crypto_balance, additional_balance);
    }

    // 7. AgoraAgent 운영 주소 교체
    // 기존 FE 호환을 위해 공개 함수 이름은 유지한다.
    public fun replace_agent<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        new_agora_agent_operator: address, // 🔄 새 AgoraAgent 운영 주소
        ctx: &TxContext,
    ) {
        // 요청자 주소 가져오기
        let caller = tx_context::sender(ctx);

        // Onwer확인
        assert!(caller == vault.owner, E_NOT_OWNER);

        vault.agora_agent_operator = new_agora_agent_operator; // 🔄 AgoraAgent 주소 교체

        vault.agora_agent_status = AGORA_STATUS_ACTIVE; // 🔄 교체 후 ACTIVE 복구
    }

    // 8. 거래한도 변경
    public fun update_trade_limit<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        new_max_trade_amount: u64,
        ctx: &TxContext,
    ) {
        // 요청자 주소 가져오기
        let caller = tx_context::sender(ctx);

        //onwer인지 검사하기
        assert!(caller == vault.owner, E_NOT_OWNER);

        assert!(new_max_trade_amount > 0, E_INVALID_EPOCH_LIMIT);
        assert!(
            new_max_trade_amount <= vault.max_epoch_trade_amount,
            E_INVALID_EPOCH_LIMIT,
        );

        // max_trade amount
        vault.max_trade_amount = new_max_trade_amount;
    }

    /// Owner가 신규 BUY를 막고 기존 CryptoT의 SELL만 허용한다.
    public fun set_reduce_only<FiatT, CryptoT>( // 🆕 위험 축소 전용 상태 설정
        vault: &mut UserVault<FiatT, CryptoT>,
        ctx: &TxContext,
    ) {
        assert!(tx_context::sender(ctx) == vault.owner, E_NOT_OWNER);
        vault.agora_agent_status = AGORA_STATUS_REDUCE_ONLY; // 🆕 SELL 전용 전환
    }

    // 9. AgoraAgent 재활성화
    // 기존 FE 호환을 위해 공개 함수 이름은 유지한다.
    public fun reactivate_agent<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        ctx: &TxContext,
    ) {
        // 요청자 주소 확인
        let caller = tx_context::sender(ctx);

        // owner인지 검사
        assert!(caller == vault.owner, E_NOT_OWNER);

        vault.agora_agent_status = AGORA_STATUS_ACTIVE; // 🔄 AgoraAgent 완전 재활성화
    }

    // 11. 일부 금액만 출금
    public fun withdraw_amount<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        amount: u64,
        ctx: &mut TxContext,
    ) {
        // 요청자 가져오기
        let caller = tx_context::sender(ctx);

        // owner 확인
        assert!(caller == vault.owner, E_NOT_OWNER);

        // Vault 잔액이 충분한지 확인
        assert!(balance::value(&vault.fiat_balance) >= amount, E_INSUFFICIENT_BALANCE);

        // Vault Balanc에서 amount만큼 분리
        let withdrawn_balance = balance::split(&mut vault.fiat_balance, amount,);

        // Balance를 Coin으로 반환
        let withdrawn_coin = coin::from_balance(withdrawn_balance, ctx,);

        // owner에게 전송
        transfer::public_transfer(withdrawn_coin, vault.owner);

    }

    // crypto 자산 일부 출금
    public fun withdraw_crypto_amount<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        amount: u64,
        ctx: &mut TxContext,
    ) {
        let caller = tx_context::sender(ctx);
        assert!(caller == vault.owner, E_NOT_OWNER);
        assert!(balance::value(&vault.crypto_balance) >= amount, E_INSUFFICIENT_BALANCE);

        let position_before = balance::value(&vault.crypto_balance);
        let released_cost = if (position_before == 0) {
            0
        } else {
            vault_policy::mul_div(vault.cost_basis_fiat, amount, position_before)
        };
        vault.cost_basis_fiat = vault.cost_basis_fiat - released_cost;
        let withdrawn_balance = balance::split(&mut vault.crypto_balance, amount);
        let withdrawn_coin = coin::from_balance(withdrawn_balance, ctx);
        transfer::public_transfer(withdrawn_coin, vault.owner);
    }

    // 기존 vault_balance는 fiat 잔액 조회로 유지한다.
    public fun vault_balance<FiatT, CryptoT>(
        vault: &UserVault<FiatT, CryptoT>,
    ): u64 {
        balance::value(&vault.fiat_balance)
    }

    public fun fiat_balance<FiatT, CryptoT>(
        vault: &UserVault<FiatT, CryptoT>,
    ): u64 {
        balance::value(&vault.fiat_balance)
    }

    public fun crypto_balance<FiatT, CryptoT>(
        vault: &UserVault<FiatT, CryptoT>,
    ): u64 {
        balance::value(&vault.crypto_balance)
    }

    public fun agora_agent_operator<FiatT, CryptoT>( // 🆕 AgoraAgent 주소 조회
        vault: &UserVault<FiatT, CryptoT>,
    ): address {
        vault.agora_agent_operator
    }

    public fun is_agora_agent_active<FiatT, CryptoT>( // 🆕 ACTIVE 상태 조회
        vault: &UserVault<FiatT, CryptoT>,
    ): bool {
        vault.agora_agent_status == AGORA_STATUS_ACTIVE
    }

    public fun is_reduce_only<FiatT, CryptoT>( // 🆕 REDUCE_ONLY 상태 조회
        vault: &UserVault<FiatT, CryptoT>,
    ): bool {
        vault.agora_agent_status == AGORA_STATUS_REDUCE_ONLY
    }

    //-----------EPOCH FUNCTIONS
    // 13. 사용한 epoch 랑 전체 epoch랑 다르면 spending을 지금 으로 바꾸고 초기화
    fun refresh_spending_epoch<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        current_epoch: u64,
    ) {
        if (vault.spending_epoch != current_epoch) {
            vault.spending_epoch = current_epoch;
            vault.spent_this_epoch = 0;
            vault.spent_crypto_this_epoch = 0;
        }
    }

    // FiatT 매수 요청의 epoch 누적 한도 검사
    fun assert_epoch_fiat_buy_amount_allowed<FiatT, CryptoT>(
        vault: &UserVault<FiatT, CryptoT>,
        fiat_amount: u64,
    ) {
        let remaining = vault.max_epoch_trade_amount - vault.spent_this_epoch;

        assert!(remaining >= fiat_amount, E_EPOCH_TRADE_LIMIT_EXCEEDED)
    }

    // CryptoT 매도 요청의 epoch 누적 한도 검사
    fun assert_epoch_crypto_sell_amount_allowed<FiatT, CryptoT>(
        vault: &UserVault<FiatT, CryptoT>,
        crypto_amount: u64,
    ) {
        let remaining =
            vault.max_epoch_crypto_sell_amount - vault.spent_crypto_this_epoch;

        assert!(
            remaining >= crypto_amount,
            E_EPOCH_CRYPTO_SELL_LIMIT_EXCEEDED,
        )
    }

    // 15. epoch 한도 변경 함수
    public fun update_epoch_trade_limit<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        new_limit: u64,
        ctx: &TxContext,
    ) {
        // 요청자 불러오기
        let caller = tx_context::sender(ctx);

        // epoch 갱신
        let current_epoch = tx_context::epoch(ctx);
        refresh_spending_epoch(vault, current_epoch);

        // 요청자가 owner인지 확인
        assert!(caller == vault.owner, E_NOT_OWNER);

        // 새로운 epoch한도가 이미 사용한 epoch사용량보다 작으면 안됨 모순 생김
        assert!(new_limit >= vault.spent_this_epoch, E_EPOCH_LIMIT_BELOW_SPENT);
        assert!(new_limit >= vault.max_trade_amount, E_INVALID_EPOCH_LIMIT);

        // 한도 반환
        vault.max_epoch_trade_amount = new_limit;
    }

    // owner가 CryptoT 1회 매도 한도를 변경한다.
    public fun update_crypto_sell_limit<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        new_limit: u64,
        ctx: &TxContext,
    ) {
        assert!(tx_context::sender(ctx) == vault.owner, E_NOT_OWNER);
        assert!(new_limit > 0, E_INVALID_CRYPTO_SELL_LIMIT);
        assert!(
            new_limit <= vault.max_epoch_crypto_sell_amount,
            E_INVALID_CRYPTO_SELL_LIMIT,
        );

        vault.max_crypto_sell_amount = new_limit;
    }

    // owner가 CryptoT epoch 누적 매도 한도를 변경한다.
    public fun update_epoch_crypto_sell_limit<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        new_limit: u64,
        ctx: &TxContext,
    ) {
        assert!(tx_context::sender(ctx) == vault.owner, E_NOT_OWNER);

        let current_epoch = tx_context::epoch(ctx);
        refresh_spending_epoch(vault, current_epoch);

        assert!(
            new_limit >= vault.spent_crypto_this_epoch,
            E_EPOCH_CRYPTO_LIMIT_BELOW_SPENT,
        );
        assert!(
            new_limit >= vault.max_crypto_sell_amount,
            E_INVALID_CRYPTO_SELL_LIMIT,
        );

        vault.max_epoch_crypto_sell_amount = new_limit;
    }

    /// 원자적 주문 실행에 적용할 사용자별 안전 정책을 설정한다.
    /// 첫 MVP는 Pool 하나만 허용하며 향후 거버넌스 기반 Registry로 확장한다.
    public fun configure_execution_policy<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        allowed_pool: address,
        max_daily_fiat_volume: u64,
        max_position_size: u64,
        max_loss_amount: u64,
        trading_start_minute_utc: u64,
        trading_end_minute_utc: u64,
        max_signal_delay_ms: u64,
        max_price_deviation_bps: u64,
        max_risk_score_bps: u64,
        loss_window_ms: u64,
        max_window_loss_amount: u64,
        ctx: &TxContext,
    ) {
        assert!(tx_context::sender(ctx) == vault.owner, E_NOT_OWNER);
        assert!(allowed_pool != @0x0, E_INVALID_EXECUTION_POLICY);
        assert!(max_risk_score_bps <= BPS_DENOMINATOR, E_INVALID_RISK_SCORE);
        assert!(loss_window_ms > 0, E_INVALID_LOSS_WINDOW);
        vault_policy::validate_configuration(
            max_daily_fiat_volume,
            max_position_size,
            trading_start_minute_utc,
            trading_end_minute_utc,
            max_signal_delay_ms,
            max_price_deviation_bps,
        );
        assert!(max_daily_fiat_volume >= vault.daily_fiat_volume, E_DAILY_VOLUME_EXCEEDED);
        assert!(max_position_size >= balance::value(&vault.crypto_balance), E_POSITION_LIMIT_EXCEEDED);
        assert!(max_loss_amount >= vault.realized_loss_amount, E_MAX_LOSS_EXCEEDED);

        vault.allowed_pool = allowed_pool;
        vault.max_daily_fiat_volume = max_daily_fiat_volume;
        vault.max_position_size = max_position_size;
        vault.max_loss_amount = max_loss_amount;
        vault.trading_start_minute_utc = trading_start_minute_utc;
        vault.trading_end_minute_utc = trading_end_minute_utc;
        vault.max_signal_delay_ms = max_signal_delay_ms;
        vault.max_price_deviation_bps = max_price_deviation_bps;
        vault.max_risk_score_bps = max_risk_score_bps;
        vault.loss_window_ms = loss_window_ms;
        vault.max_window_loss_amount = max_window_loss_amount;
    }

    /// 실현 손실의 "속도"를 감시하는 하드 스위치다.
    ///
    /// max_loss_amount는 Vault 수명 전체의 누적 손실을 보므로 짧은 시간에 벌어지는
    /// 급락을 잡지 못한다. 이 함수는 loss_window_ms 길이의 창 안에서 손실을 합산해
    /// max_window_loss_amount를 넘으면 Vault를 즉시 PAUSED로 내린다.
    ///
    /// 발동해도 지금 진행 중인 매도는 abort하지 않는다. 손실이 커지는 국면에서
    /// 포지션 축소를 되돌리면 오히려 손실을 키우기 때문이다. 이번 거래는 체결하고
    /// 다음 주문부터 차단한다. 복구는 Owner의 reactivate_agent로만 가능하다.
    fun apply_loss_kill_switch<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        loss: u64,
        now_ms: u64,
    ) {
        // 창을 벗어났으면 새 창을 열고 누적을 초기화한다.
        if (now_ms >= vault.window_started_at_ms + vault.loss_window_ms) {
            vault.window_started_at_ms = now_ms;
            vault.window_loss_amount = 0;
        };

        vault.window_loss_amount = vault.window_loss_amount + loss;

        if (vault.window_loss_amount > vault.max_window_loss_amount) {
            vault.agora_agent_status = AGORA_STATUS_PAUSED;
            event::emit(KillSwitchTriggered<FiatT, CryptoT> {
                vault_id: object::id(vault),
                window_loss_amount: vault.window_loss_amount,
                max_window_loss_amount: vault.max_window_loss_amount,
                window_started_at_ms: vault.window_started_at_ms,
                triggered_at_ms: now_ms,
            });
        };
    }

    /// 신규 포지션을 여는 BUY에만 Signal 위험도 상한을 적용한다.
    /// SELL에 같은 상한을 걸면 위험이 커진 순간 포지션을 빠져나올 수 없게 되므로
    /// SELL은 형식 검사만 하고 통과시킨다. REDUCE_ONLY 상태 정책과 같은 방향이다.
    fun assert_buy_risk_score_allowed<FiatT, CryptoT>(
        vault: &UserVault<FiatT, CryptoT>,
        risk_score_bps: u64,
    ) {
        assert!(risk_score_bps <= BPS_DENOMINATOR, E_INVALID_RISK_SCORE);
        assert!(risk_score_bps <= vault.max_risk_score_bps, E_RISK_SCORE_EXCEEDED);
    }

    public fun owner<FiatT, CryptoT>(vault: &UserVault<FiatT, CryptoT>): address {
        vault.owner
    }

    public fun signal_executed<FiatT, CryptoT>(
        vault: &UserVault<FiatT, CryptoT>,
        signal_id: vector<u8>,
    ): bool {
        table::contains(&vault.executed_signals, signal_id)
    }

    public fun daily_fiat_volume<FiatT, CryptoT>(
        vault: &UserVault<FiatT, CryptoT>,
    ): u64 {
        vault.daily_fiat_volume
    }

    public fun max_risk_score_bps<FiatT, CryptoT>(
        vault: &UserVault<FiatT, CryptoT>,
    ): u64 {
        vault.max_risk_score_bps
    }

    /// 현재 관찰 창에 누적된 실현 손실이다. Kill Switch 발동까지 남은 여유를 계산할 때 쓴다.
    public fun window_loss_amount<FiatT, CryptoT>(
        vault: &UserVault<FiatT, CryptoT>,
    ): u64 {
        vault.window_loss_amount
    }

    /// Kill Switch 발동이나 Owner의 revoke_agent로 정지된 상태인지 조회한다.
    public fun is_paused<FiatT, CryptoT>(
        vault: &UserVault<FiatT, CryptoT>,
    ): bool {
        vault.agora_agent_status == AGORA_STATUS_PAUSED
    }

    public fun realized_loss_amount<FiatT, CryptoT>(
        vault: &UserVault<FiatT, CryptoT>,
    ): u64 {
        vault.realized_loss_amount
    }

    fun refresh_volume_day<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        timestamp_ms: u64,
    ) {
        let day = vault_policy::utc_day(timestamp_ms);
        if (vault.volume_day_utc != day) {
            vault.volume_day_utc = day;
            vault.daily_fiat_volume = 0;
        };
    }

    fun assert_execution_policy<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        pool: address,
        signal_id: &vector<u8>,
        signal_timestamp_ms: u64,
        signal_price_e9: u64,
        quote_price_e9: u64,
        fiat_notional: u64,
        clock: &Clock,
    ) {
        assert!(vault.allowed_pool == pool && pool != @0x0, E_POOL_NOT_ALLOWED);
        assert!(vector::length(signal_id) > 0, E_DUPLICATE_SIGNAL);
        assert!(!table::contains(&vault.executed_signals, *signal_id), E_DUPLICATE_SIGNAL);

        let now_ms = clock::timestamp_ms(clock);
        vault_policy::assert_time_policy(
            now_ms,
            signal_timestamp_ms,
            vault.max_signal_delay_ms,
            vault.trading_start_minute_utc,
            vault.trading_end_minute_utc,
        );
        vault_policy::assert_price_deviation(
            signal_price_e9,
            quote_price_e9,
            vault.max_price_deviation_bps,
        );
        refresh_volume_day(vault, now_ms);
        assert!(
            vault.max_daily_fiat_volume - vault.daily_fiat_volume >= fiat_notional,
            E_DAILY_VOLUME_EXCEEDED,
        );
    }

    /// Package 내부 Order Executor만 호출할 수 있는 FiatT 인출 함수다.
    /// 반환된 Balance는 같은 PTB 안에서 반드시 Swap과 Vault 정산에 사용해야 한다.
    public(package) fun take_fiat_for_execution<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        pool: address,
        fiat_amount: u64,
        signal_id: &vector<u8>,
        signal_timestamp_ms: u64,
        signal_price_e9: u64,
        quote_price_e9: u64,
        risk_score_bps: u64,
        clock: &Clock,
        ctx: &TxContext,
    ): Balance<FiatT> {
        assert_agora_agent_authorized(vault, ctx);
        assert_buy_enabled(vault);
        assert_buy_risk_score_allowed(vault, risk_score_bps);
        refresh_spending_epoch(vault, tx_context::epoch(ctx));
        assert_fiat_buy_amount_allowed(vault, fiat_amount);
        assert_epoch_fiat_buy_amount_allowed(vault, fiat_amount);
        assert_execution_policy(
            vault, pool, signal_id, signal_timestamp_ms, signal_price_e9,
            quote_price_e9, fiat_amount, clock,
        );
        assert!(fiat_amount <= balance::value(&vault.fiat_balance), E_INSUFFICIENT_BALANCE);
        balance::split(&mut vault.fiat_balance, fiat_amount)
    }

    // 긴급 탈출 -----------------------------------------------------------
    //
    // 아래 두 경로는 Owner 전용이며 AgoraAgent의 정상 거래 한도를 적용하지 않는다.
    // 한도는 "Agent가 사용자 자산을 함부로 쓰지 못하게" 막는 장치인데, 자산의 주인이
    // 자기 자산을 회수하는 상황에 같은 한도를 적용하면 안전장치가 오히려 사용자를
    // 가둬버린다. PAUSED 상태에서도 반드시 동작해야 한다.

    /// 청산할 CryptoT 전량을 꺼낸다. Owner만 호출할 수 있다.
    ///
    /// 건너뛰는 검사: AgoraAgent 권한, ACTIVE/REDUCE_ONLY/PAUSED 상태,
    /// 1회·epoch·일일·포지션 한도, 거래 시간대, Signal TTL, 가격 편차, Signal 중복.
    /// 유지하는 검사: allowed_pool. Owner가 직접 설정한 Pool이므로 유지 비용이 없고,
    /// 탈취된 프런트엔드가 악성 Pool로 자금을 흘리는 것을 막는다.
    public(package) fun take_all_crypto_for_emergency<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        pool: address,
        ctx: &TxContext,
    ): Balance<CryptoT> {
        assert!(tx_context::sender(ctx) == vault.owner, E_NOT_OWNER);
        assert!(pool == vault.allowed_pool, E_POOL_NOT_ALLOWED);
        let position = balance::value(&vault.crypto_balance);
        assert!(position > 0, E_NOTHING_TO_LIQUIDATE);
        balance::withdraw_all(&mut vault.crypto_balance)
    }

    /// 청산 대금을 Vault에 넣고 포지션 회계를 정리한 뒤 Vault를 정지시킨다.
    ///
    /// 실현 손실은 기록하되 max_loss_amount로 abort하지 않는다. 긴급 청산은 이미
    /// 손실이 큰 국면에서 실행되므로, 손실 한도로 청산을 막으면 사용자가 포지션에
    /// 갇힌다. 같은 이유로 Kill Switch도 다시 돌리지 않는다.
    ///
    /// 청산 후 상태를 PAUSED로 만든다. Owner가 전량 탈출을 택한 직후 AgoraAgent가
    /// 곧바로 재매수하면 탈출의 의미가 없다. 재개는 Owner의 reactivate_agent로만 한다.
    public(package) fun settle_emergency_liquidation<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        fiat_output: Balance<FiatT>,
        crypto_sold: u64,
        min_fiat_output: u64,
        pool: address,
        now_ms: u64,
    ): u64 {
        // 최소 수령량은 유지한다. 이것까지 없으면 긴급 버튼이 곧 자산 탈취 경로가 된다.
        let output = balance::value(&fiat_output);
        assert!(output >= min_fiat_output, E_MIN_OUTPUT_NOT_MET);

        let released_cost = vault.cost_basis_fiat;
        let loss = if (released_cost > output) { released_cost - output } else { 0 };

        vault.cost_basis_fiat = 0;
        vault.realized_loss_amount = vault.realized_loss_amount + loss;
        balance::join(&mut vault.fiat_balance, fiat_output);
        vault.agora_agent_status = AGORA_STATUS_PAUSED;

        event::emit(EmergencyLiquidated<FiatT, CryptoT> {
            vault_id: object::id(vault),
            owner: vault.owner,
            crypto_sold,
            fiat_received: output,
            released_cost_basis: released_cost,
            realized_loss: loss,
            pool,
            executed_at_ms: now_ms,
        });

        output
    }

    /// AgoraAgent를 정지시키고 FiatT 잔액 전부를 Owner 지갑으로 회수한다.
    ///
    /// 정지와 회수를 한 트랜잭션으로 묶는다. 따로 실행하면 정지와 회수 사이에
    /// AgoraAgent가 마지막 주문을 끼워 넣을 수 있다.
    ///
    /// CryptoT 포지션은 건드리지 않는다. 시장가 매도가 필요하면 긴급 청산을 먼저
    /// 실행하고, 그대로 코인으로 받으려면 withdraw_crypto_amount를 쓴다.
    public fun emergency_pause_and_withdraw_fiat<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        ctx: &mut TxContext,
    ) {
        assert!(tx_context::sender(ctx) == vault.owner, E_NOT_OWNER);

        vault.agora_agent_status = AGORA_STATUS_PAUSED;

        let amount = balance::value(&vault.fiat_balance);
        assert!(amount > 0, E_NOTHING_TO_WITHDRAW);

        let withdrawn = balance::withdraw_all(&mut vault.fiat_balance);
        transfer::public_transfer(coin::from_balance(withdrawn, ctx), vault.owner);

        event::emit(EmergencyFiatWithdrawn<FiatT, CryptoT> {
            vault_id: object::id(vault),
            owner: vault.owner,
            fiat_withdrawn: amount,
            crypto_left_in_vault: balance::value(&vault.crypto_balance),
        });
    }

    /// Order Book DEX는 유동성이 모자라면 입력을 다 쓰지 못하고 남긴다.
    /// 남은 입력은 어떤 경우에도 실행자가 아니라 같은 Vault로 돌아와야 한다.
    public(package) fun return_fiat_remainder<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        remainder: Balance<FiatT>,
    ) {
        balance::join(&mut vault.fiat_balance, remainder);
    }

    public(package) fun return_crypto_remainder<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        remainder: Balance<CryptoT>,
    ) {
        balance::join(&mut vault.crypto_balance, remainder);
    }

    public(package) fun settle_buy_execution<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        crypto_output: Balance<CryptoT>,
        fiat_amount: u64,
        min_crypto_output: u64,
        signal_id: vector<u8>,
    ): u64 {
        // 실제 출력량과 최대 포지션을 확인한 뒤에만 Vault 잔액에 합친다.
        let output = balance::value(&crypto_output);
        assert!(output >= min_crypto_output, E_MIN_OUTPUT_NOT_MET);
        assert!(
            vault.max_position_size - balance::value(&vault.crypto_balance) >= output,
            E_POSITION_LIMIT_EXCEEDED,
        );
        balance::join(&mut vault.crypto_balance, crypto_output);
        // Swap 성공 후에만 각종 사용량과 Signal replay 기록을 확정한다.
        vault.spent_this_epoch = vault.spent_this_epoch + fiat_amount;
        vault.daily_fiat_volume = vault.daily_fiat_volume + fiat_amount;
        vault.cost_basis_fiat = vault.cost_basis_fiat + fiat_amount;
        table::add(&mut vault.executed_signals, signal_id, true);
        output
    }

    public(package) fun take_crypto_for_execution<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        pool: address,
        crypto_amount: u64,
        expected_fiat_output: u64,
        signal_id: &vector<u8>,
        signal_timestamp_ms: u64,
        signal_price_e9: u64,
        quote_price_e9: u64,
        risk_score_bps: u64,
        clock: &Clock,
        ctx: &TxContext,
    ): Balance<CryptoT> {
        assert_agora_agent_authorized(vault, ctx);
        // SELL은 위험도 상한 대신 형식 검사만 한다. 근거는 assert_buy_risk_score_allowed 참고.
        assert!(risk_score_bps <= BPS_DENOMINATOR, E_INVALID_RISK_SCORE);
        refresh_spending_epoch(vault, tx_context::epoch(ctx));
        assert_crypto_sell_amount_allowed(vault, crypto_amount);
        assert_epoch_crypto_sell_amount_allowed(vault, crypto_amount);
        assert_execution_policy(
            vault, pool, signal_id, signal_timestamp_ms, signal_price_e9,
            quote_price_e9, expected_fiat_output, clock,
        );
        assert!(crypto_amount <= balance::value(&vault.crypto_balance), E_INSUFFICIENT_BALANCE);
        balance::split(&mut vault.crypto_balance, crypto_amount)
    }

    public(package) fun settle_sell_execution<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        fiat_output: Balance<FiatT>,
        crypto_amount: u64,
        position_before: u64,
        min_fiat_output: u64,
        signal_id: vector<u8>,
        now_ms: u64,
    ): u64 {
        let output = balance::value(&fiat_output);
        assert!(output >= min_fiat_output, E_MIN_OUTPUT_NOT_MET);
        assert!(
            vault.max_daily_fiat_volume - vault.daily_fiat_volume >= output,
            E_DAILY_VOLUME_EXCEEDED,
        );

        // 전체 취득 원가 중 이번 매도 수량에 해당하는 원가를 비례 배분한다.
        let released_cost = if (position_before == 0) {
            0
        } else {
            vault_policy::mul_div(vault.cost_basis_fiat, crypto_amount, position_before)
        };
        // 매도 대금이 배분 원가보다 작을 때만 실현 손실로 누적한다.
        let loss = if (released_cost > output) { released_cost - output } else { 0 };
        assert!(vault.max_loss_amount - vault.realized_loss_amount >= loss, E_MAX_LOSS_EXCEEDED);

        vault.cost_basis_fiat = vault.cost_basis_fiat - released_cost;
        vault.realized_loss_amount = vault.realized_loss_amount + loss;
        // 누적 한도를 통과한 손실이라도 속도가 비정상이면 여기서 Vault를 정지시킨다.
        apply_loss_kill_switch(vault, loss, now_ms);
        vault.spent_crypto_this_epoch = vault.spent_crypto_this_epoch + crypto_amount;
        vault.daily_fiat_volume = vault.daily_fiat_volume + output;
        balance::join(&mut vault.fiat_balance, fiat_output);
        table::add(&mut vault.executed_signals, signal_id, true);
        output
    }

}


// T: Vault에 보관할 코인 종류
// owner: 출금 가능한 사용자
// agora_agent_operator: 거래만 요청할 수 있는 AgoraAgent 운영 주소
// agora_agent_status: ACTIVE / REDUCE_ONLY / PAUSED 실행 상태
// Balance<T>: 실제 보관 자산

// ctx: 누가 트랜잭션을 보냈는가
// 새로운 객체 ID를 어떻게 만들 것인가
// 현재 트랜잭션의 여러 시스템 정보
