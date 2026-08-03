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
        /// Vault별로 이미 성공한 Signal ID를 저장해 중복 실행을 차단한다.
        executed_signals: Table<vector<u8>, bool>,

        // [DYNAMIC BAG 전환 지점]
        // 나중에 여러 crypto를 지원할 때 crypto_balance 한 필드를
        // AssetKey<CryptoT> -> Balance<CryptoT> Dynamic Field/Bag 정책으로 바꾼다.
        // 그때도 FiatT는 BUY 입력, 허용된 CryptoT는 SELL 입력이라는 역할 검사를 유지한다.

    }

    // 이벤트 구조체
    public struct FiatBuyRequested<phantom FiatT, phantom CryptoT> has copy, drop {
        vault_id: ID,
        agora_agent_operator: address, // 🔄 이벤트 실행자를 AgoraAgent로 명시
        fiat_amount: u64,
        epoch: u64,
        epoch_fiat_spent_after: u64,
    }

    public struct CryptoSellRequested<phantom FiatT, phantom CryptoT> has copy, drop {
        vault_id: ID,
        agora_agent_operator: address, // 🔄 이벤트 실행자를 AgoraAgent로 명시
        crypto_amount: u64,
        epoch: u64,
        epoch_crypto_spent_after: u64,
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

    // BUY 요청: FiatT 잔액만 검사한다.
    // 기존 FE 호환용 이름이며 내부 동작은 request_buy와 같다.
    public(package) fun request_trade<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        fiat_amount: u64,
        ctx: &TxContext,
    ) {
        request_buy(vault, fiat_amount, ctx)
    }

    // BUY 요청: FiatT -> CryptoT 방향만 허용한다.
    public(package) fun request_buy<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        fiat_amount: u64,
        ctx: &TxContext,
    ) {
        assert_agora_agent_authorized(vault, ctx); // 🔄 AgoraAgent만 BUY 요청 가능
        assert_buy_enabled(vault); // 🆕 REDUCE_ONLY BUY 차단

        // Epoch 가져오기
        let current_epoch = tx_context::epoch(ctx);

        // 새로운 epoch면 누적 사용량 초기화
        refresh_spending_epoch(vault, current_epoch);

        // 1회 거래 한도
        assert_fiat_buy_amount_allowed(vault, fiat_amount);

        // epoch 전체 누적 한도
        assert_epoch_fiat_buy_amount_allowed(vault, fiat_amount);

        // BUY는 fiat_balance만 입력으로 사용할 수 있다.
        assert!(fiat_amount <= balance::value(&vault.fiat_balance), E_INSUFFICIENT_BALANCE);

        vault.spent_this_epoch = vault.spent_this_epoch + fiat_amount;

        event::emit(FiatBuyRequested<FiatT, CryptoT> {
            vault_id: object::id(vault),
            agora_agent_operator: tx_context::sender(ctx), // 🔄 AgoraAgent 실행 주소 기록
            fiat_amount,
            epoch: current_epoch,
            epoch_fiat_spent_after: vault.spent_this_epoch,
        })
    }

    // SELL 요청: CryptoT -> FiatT 방향만 허용한다.
    // [DYNAMIC BAG 전환 시]
    // crypto_balance 대신 선택한 AssetKey<CryptoT>의 Balance<CryptoT>를 빌리되,
    // 해당 타입이 owner가 허용한 SELL 자산인지 반드시 먼저 검사한다.
    public(package) fun request_sell<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        crypto_amount: u64,
        ctx: &TxContext,
    ) {
        assert_agora_agent_authorized(vault, ctx); // 🆕 REDUCE_ONLY에서도 SELL 허용

        let current_epoch = tx_context::epoch(ctx);
        refresh_spending_epoch(vault, current_epoch);

        assert_crypto_sell_amount_allowed(vault, crypto_amount);
        assert_epoch_crypto_sell_amount_allowed(vault, crypto_amount);

        // SELL은 crypto_balance만 입력으로 사용할 수 있다.
        assert!(
            crypto_amount <= balance::value(&vault.crypto_balance),
            E_INSUFFICIENT_BALANCE,
        );

        vault.spent_crypto_this_epoch =
            vault.spent_crypto_this_epoch + crypto_amount;

        event::emit(CryptoSellRequested<FiatT, CryptoT> {
            vault_id: object::id(vault),
            agora_agent_operator: tx_context::sender(ctx), // 🔄 AgoraAgent 실행 주소 기록
            crypto_amount,
            epoch: current_epoch,
            epoch_crypto_spent_after: vault.spent_crypto_this_epoch,
        })
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
        ctx: &TxContext,
    ) {
        assert!(tx_context::sender(ctx) == vault.owner, E_NOT_OWNER);
        assert!(allowed_pool != @0x0, E_INVALID_EXECUTION_POLICY);
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
        clock: &Clock,
        ctx: &TxContext,
    ): Balance<FiatT> {
        assert_agora_agent_authorized(vault, ctx);
        assert_buy_enabled(vault);
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
        clock: &Clock,
        ctx: &TxContext,
    ): Balance<CryptoT> {
        assert_agora_agent_authorized(vault, ctx);
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
