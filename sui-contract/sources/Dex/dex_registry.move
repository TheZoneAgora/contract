module agent_market::dex_registry {
    /// 거래 장소 식별자다. Indexer와 실행 서버가 어느 경로로 체결됐는지 구분할 때 쓴다.
    ///
    /// Move에는 동적 디스패치가 없으므로 장소마다 별도 executor 모듈을 둔다.
    /// 대신 권한·상태·위험도·한도·중복 Signal·시간·가격 편차·최소 수령량 검사는
    /// 모두 investment_vault의 take_*_for_execution과 settle_*_execution에 모여 있어
    /// 어떤 장소로 체결하든 같은 안전장치가 적용된다.
    ///
    ///   VENUE_DEEPBOOK agent_market::deepbook_executor (유일한 실행 경로)
    ///
    /// 예전에는 VENUE_MOCK(가짜 DEX 경로)이 있었으나, 실행 경로가 둘이면 갈라진다는
    /// 문제가 실제로 드러나 제거했다 — 거래 수수료를 DeepBook 경로에만 넣고 mock에는
    /// 빠뜨린 적이 있다. 테스트는 이제 Vault 원시 함수를 직접 호출한다(vault_harness).
    ///
    /// Vault 정책은 여전히 allowed_pool 주소 하나만 허용한다.
    /// 다중 Pool과 라우팅은 보안 감사 범위가 확정된 뒤에 확장한다.
    /// 0은 제거된 VENUE_MOCK이 쓰던 값이라 재사용하지 않는다.
    /// 이미 기록된 이벤트를 나중에 잘못 해석하게 된다.
    const VENUE_DEEPBOOK: u8 = 1;

    public fun venue_deepbook(): u8 { VENUE_DEEPBOOK }
}
