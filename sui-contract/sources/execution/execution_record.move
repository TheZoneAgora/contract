module agent_market::execution_record {
    /// Indexer와 향후 실제 DEX Adapter가 공통으로 사용할 주문 방향 값이다.
    public fun buy_side(): u8 { 0 }
    public fun sell_side(): u8 { 1 }
}
