module agent_market::investment_vault {
    use sui::balance::{Self, Balance};
    use sui::object::{Self, UID, ID};
    use sui::coin::{Self, Coin};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::event;

    /// 오류코드
    const E_NOT_OWNER: u64 = 1;
    const E_NOT_AGENT: u64 = 2;
    const E_AGENT_INACTIVE: u64 = 3;
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


    /// 사용자가 소유권을 유지하면서
    /// Agent에게 제한된 거래 궎나만 주는 투자 금고 Vault
    public struct UserVault<phantom FiatT, phantom CryptoT> has key {
        // key가 있음으로 UID 필수
        id: UID,

        /// 최종 출금 권한을 가진 사용자
        owner: address,

        /// 거래를 요철할 수 있는 Agent 운영지갑
        agent_operator: address,

        /// agent 거래 권한 On off 여부
        agent_active: bool,

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

        // [DYNAMIC BAG 전환 지점]
        // 나중에 여러 crypto를 지원할 때 crypto_balance 한 필드를
        // AssetKey<CryptoT> -> Balance<CryptoT> Dynamic Field/Bag 정책으로 바꾼다.
        // 그때도 FiatT는 BUY 입력, 허용된 CryptoT는 SELL 입력이라는 역할 검사를 유지한다.

    }

    // 이벤트 구조체
    public struct FiatBuyRequested<phantom FiatT, phantom CryptoT> has copy, drop {
        vault_id: ID,
        agent_operator: address,
        fiat_amount: u64,
        epoch: u64,
        epoch_fiat_spent_after: u64,
    }

    public struct CryptoSellRequested<phantom FiatT, phantom CryptoT> has copy, drop {
        vault_id: ID,
        agent_operator: address,
        crypto_amount: u64,
        epoch: u64,
        epoch_crypto_spent_after: u64,
    }

    // 함수 (15개 함수) --------------------------------------

    // 1. vault 생성
    public fun create_vault<FiatT, CryptoT>(
        deposit: Coin<FiatT>, // 사용자가 전달한 기준 자산
        agent_operator: address, // Agent 지갑 주소
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
            agent_operator,
            agent_active: true,
            max_trade_amount,
            max_epoch_trade_amount,
            spent_this_epoch: 0,
            max_crypto_sell_amount,
            max_epoch_crypto_sell_amount,
            spent_crypto_this_epoch: 0,
            spending_epoch: current_epoch,
            fiat_balance,
            crypto_balance,
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

        // 4. 두 Balance를 각각 같은 타입의 Coin 객체로 변환한다.
        let withdrawn_fiat_coin = coin::from_balance(withdrawn_fiat_balance, ctx);
        let withdrawn_crypto_coin = coin::from_balance(withdrawn_crypto_balance, ctx);

        // 5. fiat와 crypto를 모두 Vault owner 주소로 전송한다.
        transfer::public_transfer(withdrawn_fiat_coin, vault.owner);
        transfer::public_transfer(withdrawn_crypto_coin, vault.owner);


    }

    // 3. 권한끄기
    public fun revoke_agent<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        ctx: &TxContext,
    ) {
        // 1. 현재 트랜잭션 요청을 보낸 주소를 가져온다.
        let caller = tx_context::sender(ctx);

        // 2. 요청자가 Vault owner인지 검사한다.
        // owner가 아니면 E_NOT_OWNER 오류로 중단한다.
        assert!(caller == vault.owner, E_NOT_OWNER);

        // 3. vault의 agent_active 값을 false로 변경한다.
        vault.agent_active = false;
    }

    // 4. Agent 거래 요청 자격 있는 검사
    fun assert_agent_authorized<FiatT, CryptoT>(
        vault: &UserVault<FiatT, CryptoT>,
        ctx: &TxContext,
    ){
        // 1. 현재 트랜잭션 요청을 보낸 주소를 가져온다.
        let caller = tx_context::sender(ctx);

        // 2. 요청 주소가 vault.agent_operator와 같은지 확인한다.
        // 다르면 E_NOT_AGENT 오류로 중단한다.
        assert!(caller == vault.agent_operator, E_NOT_AGENT);

        // 3. vault.agent_active가 true인지 확인한다.
        // false라면 E_AGENT_INACTIVE 오류로 중단한다.
        assert!(vault.agent_active, E_AGENT_INACTIVE);
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

    // 7. Agent 교채
    public fun replace_agent<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        new_agent_operator: address,
        ctx: &TxContext,
    ) {
        // 요청자 주소 가져오기
        let caller = tx_context::sender(ctx);

        // Onwer확인
        assert!(caller == vault.owner, E_NOT_OWNER);

        // 기존 agent_op를 새 주소로 변경
        vault.agent_operator = new_agent_operator;

        // agent활성화
        vault.agent_active = true;
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

    // 9. Agent 제활성화
    public fun reactivate_agent<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        ctx: &TxContext,
    ) {
        // 요청자 주소 확인
        let caller = tx_context::sender(ctx);

        // owner인지 검사
        assert!(caller == vault.owner, E_NOT_OWNER);

        // agent_active를 true로 변경
        vault.agent_active = true;
    }

    // BUY 요청: FiatT 잔액만 검사한다.
    // 기존 FE 호환용 이름이며 내부 동작은 request_buy와 같다.
    public fun request_trade<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        fiat_amount: u64,
        ctx: &TxContext,
    ) {
        request_buy(vault, fiat_amount, ctx)
    }

    // BUY 요청: FiatT -> CryptoT 방향만 허용한다.
    public fun request_buy<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        fiat_amount: u64,
        ctx: &TxContext,
    ) {
        // Agent 권한 검사
        assert_agent_authorized(vault, ctx);

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
            agent_operator: tx_context::sender(ctx),
            fiat_amount,
            epoch: current_epoch,
            epoch_fiat_spent_after: vault.spent_this_epoch,
        })
    }

    // SELL 요청: CryptoT -> FiatT 방향만 허용한다.
    // [DYNAMIC BAG 전환 시]
    // crypto_balance 대신 선택한 AssetKey<CryptoT>의 Balance<CryptoT>를 빌리되,
    // 해당 타입이 owner가 허용한 SELL 자산인지 반드시 먼저 검사한다.
    public fun request_sell<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        crypto_amount: u64,
        ctx: &TxContext,
    ) {
        assert_agent_authorized(vault, ctx);

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
            agent_operator: tx_context::sender(ctx),
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

}


// T: Vault에 보관할 코인 종류
// owner: 출금 가능한 사용자
// agent_operator: 거래만 요청할 Agent
// agent_active: Agent 정지 여부
// Balance<T>: 실제 보관 자산

// ctx: 누가 트랜잭션을 보냈는가
// 새로운 객체 ID를 어떻게 만들 것인가
// 현재 트랜잭션의 여러 시스템 정보
