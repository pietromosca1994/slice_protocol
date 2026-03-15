/// # SPVRegistry
///
/// Singleton shared registry that tracks every pool ever created by any SPV
/// in the securitisation protocol.
///
/// ## Responsibilities
/// - Maintaining an ordered list of all `PoolState` object IDs
/// - Providing a per-SPV index (spv address → pool IDs they own)
/// - Storing lightweight metadata (`PoolEntry`) for each pool without
///   duplicating the full `PoolState` fields
/// - Serving as the single on-chain source of truth for UI enumeration
///
/// ## IOTA Move design notes
/// - `SPVRegistry` is a shared object; any contract or read-only RPC call
///   can enumerate pools from it.
/// - `SPVRegistryAdminCap` is the only key that allows direct admin mutations
///   (e.g. deactivating a pool entry).
/// - `register_pool` is a `public` (non-entry) function called internally by
///   `pool_contract::create_pool`; it is not directly invokable by end users.
/// - `spv_pools` maps each SPV address to a `vector<ID>` of pool object IDs;
///   vectors are append-only from this module.
#[allow(duplicate_alias)]
module spv::spv_registry {
    use iota::object::{Self, UID, ID};
    use iota::table::{Self, Table};
    use iota::transfer;
    use iota::tx_context::{Self, TxContext};
    use iota::clock::{Self, Clock};
    use spv::events;
    use spv::errors;

    // ─── Pool entry (stored per pool ID) ─────────────────────────────────────

    /// Lightweight metadata record stored for every registered pool.
    /// Does not duplicate `PoolState` fields — callers fetch the full object
    /// by `pool_obj_id` via RPC when they need more detail.
    public struct PoolEntry has store, copy, drop {
        pool_obj_id:               ID,      // Object ID of the corresponding PoolState
        spv:                       address, // SPV that created this pool
        created_at:                u64,     // ms timestamp of creation
        active:                    bool,    // false if admin-deactivated
        securitization_package_id: address, // Package ID of the per-pool securitization deployment
    }

    // ─── Capability ───────────────────────────────────────────────────────────

    public struct SPVRegistryAdminCap has key, store { id: UID }

    // ─── Shared registry ──────────────────────────────────────────────────────

    public struct SPVRegistry has key {
        id:          UID,
        /// All pool object IDs in insertion order — the canonical enumeration list.
        pool_ids:    vector<ID>,
        /// Per-pool metadata keyed by pool object ID.
        pool_index:  Table<ID, PoolEntry>,
        /// Per-SPV pool list keyed by SPV address.
        spv_pools:   Table<address, vector<ID>>,
        /// Total number of pools ever registered (never decrements).
        pool_count:  u64,
    }

    // ─── Init ─────────────────────────────────────────────────────────────────

    fun init(ctx: &mut TxContext) {
        let registry = SPVRegistry {
            id:         object::new(ctx),
            pool_ids:   vector[],
            pool_index: table::new(ctx),
            spv_pools:  table::new(ctx),
            pool_count: 0,
        };
        transfer::share_object(registry);

        let cap = SPVRegistryAdminCap { id: object::new(ctx) };
        transfer::transfer(cap, tx_context::sender(ctx));
    }

    // ─── Internal registration (called by pool_contract::create_pool) ─────────

    /// Register a newly created pool.
    /// This is `public` so `pool_contract` can call it as a module dependency,
    /// but it is NOT an `entry` function — end users cannot invoke it directly.
    ///
    /// # Parameters
    /// - `pool_obj_id`                Object ID of the freshly shared `PoolState`
    /// - `spv`                        Address of the SPV that owns this pool
    /// - `securitization_package_id`  Address of the per-pool securitization package
    public fun register_pool(
        registry:                    &mut SPVRegistry,
        pool_obj_id:                 ID,
        spv:                         address,
        securitization_package_id:   address,
        clock:                       &Clock,
        _ctx:                        &mut TxContext,
    ) {
        assert!(
            !table::contains(&registry.pool_index, pool_obj_id),
            errors::pool_already_registered()
        );

        let entry = PoolEntry {
            pool_obj_id,
            spv,
            created_at:                clock::timestamp_ms(clock),
            active:                    true,
            securitization_package_id,
        };

        vector::push_back(&mut registry.pool_ids, pool_obj_id);
        table::add(&mut registry.pool_index, pool_obj_id, entry);

        // Initialise the per-SPV list lazily
        if (!table::contains(&registry.spv_pools, spv)) {
            table::add(&mut registry.spv_pools, spv, vector[]);
        };
        vector::push_back(
            table::borrow_mut(&mut registry.spv_pools, spv),
            pool_obj_id,
        );

        registry.pool_count = registry.pool_count + 1;

        events::emit_pool_registered(pool_obj_id, spv, clock::timestamp_ms(clock));
    }

    // ─── Admin mutations ──────────────────────────────────────────────────────

    /// Soft-deactivate a pool entry (e.g. erroneously created pool).
    /// Does not remove the entry — the object ID remains in `pool_ids`.
    public entry fun deactivate_pool(
        _cap:        &SPVRegistryAdminCap,
        registry:    &mut SPVRegistry,
        pool_obj_id: ID,
    ) {
        assert!(
            table::contains(&registry.pool_index, pool_obj_id),
            errors::pool_not_registered()
        );
        let entry = table::borrow_mut(&mut registry.pool_index, pool_obj_id);
        entry.active = false;
    }

    /// Re-activate a previously deactivated pool entry.
    public entry fun reactivate_pool(
        _cap:        &SPVRegistryAdminCap,
        registry:    &mut SPVRegistry,
        pool_obj_id: ID,
    ) {
        assert!(
            table::contains(&registry.pool_index, pool_obj_id),
            errors::pool_not_registered()
        );
        let entry = table::borrow_mut(&mut registry.pool_index, pool_obj_id);
        entry.active = true;
    }

    // ─── Read-only accessors ──────────────────────────────────────────────────

    /// Total number of pools ever registered.
    public fun pool_count(registry: &SPVRegistry): u64 {
        registry.pool_count
    }

    /// Ordered list of every pool object ID (active and inactive).
    public fun all_pool_ids(registry: &SPVRegistry): &vector<ID> {
        &registry.pool_ids
    }

    /// Returns the list of pool object IDs owned by `spv`.
    /// Returns an empty vector if the SPV has never created a pool.
    public fun pools_for_spv(registry: &SPVRegistry, spv: address): vector<ID> {
        if (!table::contains(&registry.spv_pools, spv)) {
            return vector[]
        };
        *table::borrow(&registry.spv_pools, spv)
    }

    /// Returns true if `pool_obj_id` is known to the registry.
    public fun pool_exists(registry: &SPVRegistry, pool_obj_id: ID): bool {
        table::contains(&registry.pool_index, pool_obj_id)
    }

    /// Fetch the full `PoolEntry` record for a pool.
    public fun get_pool_entry(registry: &SPVRegistry, pool_obj_id: ID): &PoolEntry {
        assert!(
            table::contains(&registry.pool_index, pool_obj_id),
            errors::pool_not_registered()
        );
        table::borrow(&registry.pool_index, pool_obj_id)
    }

    // ─── PoolEntry field accessors ────────────────────────────────────────────

    public fun entry_pool_obj_id(e: &PoolEntry): ID                      { e.pool_obj_id }
    public fun entry_spv(e: &PoolEntry): address                         { e.spv }
    public fun entry_created_at(e: &PoolEntry): u64                      { e.created_at }
    public fun entry_active(e: &PoolEntry): bool                         { e.active }
    public fun entry_securitization_package_id(e: &PoolEntry): address   { e.securitization_package_id }

    // ─── Test-only helpers ────────────────────────────────────────────────────

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx);
    }
}
