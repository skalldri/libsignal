# Missing libsignal React Native JSI Bindings: SenderKey Group Cipher Functions

## Summary

The `react-native-libsignal` C++ JSI bindings are missing 4 critical functions needed for Signal Sender Key group encryption. These functions exist in the compiled Rust library and are declared in `signal_ffi.h`, but were intentionally **skipped** by `gen_jsi_bindings.py` because they take callback struct parameters (`SenderKeyStore`) that the code generator doesn't handle.

**The fix**: Add hand-written JSI bindings for 4 C FFI functions that accept a `SignalFfiBridgeSenderKeyStoreStruct` callback struct, bridging JavaScript SenderKeyStore methods into C function pointers.

---

## The 4 Missing Functions

### C FFI Signatures (from `cpp/signal_ffi.h`)

```c
// Line 2501
SignalFfiError *signal_sender_key_distribution_message_create(
    SignalMutPointerSenderKeyDistributionMessage *out,
    SignalConstPointerProtocolAddress sender,
    SignalUuid distribution_id,
    SignalConstPointerFfiSenderKeyStoreStruct store
);

// Line 2291
SignalFfiError *signal_process_sender_key_distribution_message(
    SignalConstPointerProtocolAddress sender,
    SignalConstPointerSenderKeyDistributionMessage sender_key_distribution_message,
    SignalConstPointerFfiSenderKeyStoreStruct store
);

// Line 1941
SignalFfiError *signal_group_encrypt_message(
    SignalMutPointerCiphertextMessage *out,
    SignalConstPointerProtocolAddress sender,
    SignalUuid distribution_id,
    SignalBorrowedBuffer message,
    SignalConstPointerFfiSenderKeyStoreStruct store
);

// Line 1939
SignalFfiError *signal_group_decrypt_message(
    SignalOwnedBuffer *out,
    SignalConstPointerProtocolAddress sender,
    SignalBorrowedBuffer message,
    SignalConstPointerFfiSenderKeyStoreStruct store
);
```

### Expected JavaScript Names (from `lib/Native.js` line 34)

These names are destructured from the `__libsignal_native` HostObject but are currently `undefined`:

```javascript
SenderKeyDistributionMessage_Create(sender, distributionId, store)  → Promise<SenderKeyDistributionMessage>
SenderKeyDistributionMessage_Process(sender, skdm, store)           → Promise<void>
GroupCipher_EncryptMessage(sender, distributionId, message, store)   → Promise<CiphertextMessage>
GroupCipher_DecryptMessage(sender, message, store)                   → Promise<Uint8Array>
```

---

## Why They're Missing

### Root Cause: `gen_jsi_bindings.py` line 569-572

```python
# Skip functions with complex callback struct params (stores, listeners)
# These need special hand-written implementations
if func.has_store_params:
    return True, "has callback struct params (needs hand-written implementation)"
```

The code generator identifies that these functions take `SignalConstPointerFfiSenderKeyStoreStruct` parameters (categorized as `callback_struct`) and skips them because it doesn't know how to auto-generate JSI bindings for callback structs.

### What Is a Callback Struct?

The `SenderKeyStore` is passed to the Rust FFI as a struct containing C function pointers. When the Rust code needs to load or save a SenderKeyRecord, it calls back through these function pointers into the caller's code.

```c
// signal_ffi.h lines 1008-1021
typedef int (*SignalFfiBridgeSenderKeyStoreLoadSenderKey)(
    void *ctx,
    SignalMutPointerSenderKeyRecord *out,
    SignalMutPointerProtocolAddress sender,
    SignalUuid distribution_id
);

typedef int (*SignalFfiBridgeSenderKeyStoreStoreSenderKey)(
    void *ctx,
    SignalMutPointerProtocolAddress sender,
    SignalUuid distribution_id,
    SignalMutPointerSenderKeyRecord record
);

typedef void (*SignalFfiBridgeSenderKeyStoreDestroy)(void *ctx);

typedef struct {
    void *ctx;
    SignalFfiBridgeSenderKeyStoreLoadSenderKey load_sender_key;
    SignalFfiBridgeSenderKeyStoreStoreSenderKey store_sender_key;
    SignalFfiBridgeSenderKeyStoreDestroy destroy;
} SignalFfiBridgeSenderKeyStoreStruct;

typedef SignalFfiBridgeSenderKeyStoreStruct SignalSenderKeyStore;

typedef struct {
    const SignalSenderKeyStore *raw;
} SignalConstPointerFfiSenderKeyStoreStruct;
```

### Key Insight: These Are Synchronous C FFI Calls

Unlike the CPromise-based async functions (which the generator already handles), these 4 functions are **synchronous** at the C FFI level — they return `SignalFfiError*` directly, not via a callback. The Rust runtime internally blocks the calling thread while it calls the store callbacks.

This means the JSI implementation does **NOT** need CPromise/async plumbing. The function will:
1. Be called from JavaScript
2. Construct the callback struct with C function pointers
3. Those C function pointers call back into JavaScript (synchronously, on the same thread)
4. The C FFI call returns synchronously with the result

However, since the JavaScript SenderKeyStore interface uses `async` methods (returning Promises), the JSI binding will likely need to expose these as async/Promise-returning functions, running the actual FFI call on a background thread and using the CallInvoker to marshal results back to the JS thread.

---

## Implementation Guide

### What the JavaScript Caller Expects

From `lib/Native.js` (the React Native libsignal JS layer), these functions are called with a JavaScript object implementing the `SenderKeyStore` interface:

```typescript
// From upstream signalapp/libsignal node/ts/index.ts
abstract class SenderKeyStore {
    abstract _saveSenderKey(
        sender: ProtocolAddress,    // native handle
        distributionId: Uuid,       // Uint8Array (16 bytes)
        record: SenderKeyRecord     // native handle
    ): Promise<void>;

    abstract _getSenderKey(
        sender: ProtocolAddress,    // native handle
        distributionId: Uuid        // Uint8Array (16 bytes)
    ): Promise<SenderKeyRecord | null>;
}
```

The JS caller passes a store object with `_saveSenderKey` and `_getSenderKey` methods. The C++ code must call these JS methods when the Rust FFI invokes the store callbacks.

### Implementation Strategy

Add hand-written JSI bindings in a new file (e.g., `cpp/sender_key_bindings.cpp`) or in `LibsignalTurboModule.cpp`, registered alongside the auto-generated bindings.

#### Step 1: Create C Callback Functions

```cpp
// Context structure passed through the void* ctx pointer
struct JsiSenderKeyStoreContext {
    jsi::Runtime* runtime;
    jsi::Object* storeObject;  // The JS SenderKeyStore instance
};

// C callback for load_sender_key
static int jsi_load_sender_key(
    void* ctx,
    SignalMutPointerSenderKeyRecord* out,
    SignalMutPointerProtocolAddress sender,
    SignalUuid distribution_id
) {
    auto* context = static_cast<JsiSenderKeyStoreContext*>(ctx);
    auto& rt = *context->runtime;
    auto& store = *context->storeObject;

    // Call store._getSenderKey(sender, distributionId)
    // Convert sender (ProtocolAddress handle) to JSI value
    // Convert distribution_id (UUID) to JSI Uint8Array
    // Call the JS method synchronously
    // If result is null, set out->raw = nullptr and return 0
    // If result is a SenderKeyRecord, extract its native handle and set out->raw
    // Return 0 on success, non-zero on error
}

// C callback for store_sender_key
static int jsi_store_sender_key(
    void* ctx,
    SignalMutPointerProtocolAddress sender,
    SignalUuid distribution_id,
    SignalMutPointerSenderKeyRecord record
) {
    auto* context = static_cast<JsiSenderKeyStoreContext*>(ctx);
    auto& rt = *context->runtime;
    auto& store = *context->storeObject;

    // Call store._saveSenderKey(sender, distributionId, record)
    // Return 0 on success, non-zero on error
}

// C callback for destroy (cleanup)
static void jsi_sender_key_store_destroy(void* ctx) {
    delete static_cast<JsiSenderKeyStoreContext*>(ctx);
}
```

#### Step 2: Register the 4 JSI Functions

```cpp
// Example for SenderKeyDistributionMessage_Create
functions_["SenderKeyDistributionMessage_Create"] = [this](
    jsi::Runtime& rt,
    const jsi::Value& thisVal,
    const jsi::Value* args,
    size_t count
) -> jsi::Value {
    // args[0] = sender (ProtocolAddress native handle)
    // args[1] = distributionId (Uint8Array, 16 bytes UUID)
    // args[2] = store (JS SenderKeyStore object)

    auto senderHandle = /* extract ProtocolAddress from args[0] */;
    auto distId = /* extract SignalUuid from args[1] Uint8Array */;

    // Build the callback struct
    auto* ctx = new JsiSenderKeyStoreContext{&rt, /* reference to args[2] */};
    SignalFfiBridgeSenderKeyStoreStruct storeStruct = {
        .ctx = ctx,
        .load_sender_key = jsi_load_sender_key,
        .store_sender_key = jsi_store_sender_key,
        .destroy = jsi_sender_key_store_destroy,
    };
    SignalConstPointerFfiSenderKeyStoreStruct storePtr = {&storeStruct};

    // Call the C FFI function
    SignalMutPointerSenderKeyDistributionMessage out = {nullptr};
    SignalConstPointerProtocolAddress senderPtr = {senderHandle};

    SignalFfiError* err = signal_sender_key_distribution_message_create(
        &out, senderPtr, distId, storePtr
    );

    // Clean up and handle error
    if (err) { /* throw JS error */ }

    // Return the native handle as a JSI value
    return /* wrap out.raw as native handle */;
};
```

#### Step 3: Handle the Synchronous Callback Challenge

The critical challenge: when the Rust code calls `load_sender_key` or `store_sender_key` via the C function pointers, it happens **synchronously on the same thread**. The C function pointer must:

1. Call the JavaScript `_getSenderKey` / `_saveSenderKey` method
2. These JS methods return **Promises** (they're async)
3. The C callback must wait for the Promise to resolve before returning

**Two approaches:**

**Approach A (Recommended): Make the store methods synchronous**

Since the C FFI is synchronous, the simplest approach is to ensure the JS SenderKeyStore methods are synchronous too. Our SenderKeyStore implementation (`sender-key-store.ts`) uses synchronous SQLite operations under the hood. We could:
- Add synchronous versions of the store methods (`_getSenderKeySync`, `_saveSenderKeySync`)
- Or have the C++ code call the methods and handle the result synchronously (if they return non-Promise values)

**Approach B: Block on Promise resolution**

If the store methods must remain async, the C++ callback would need to spin/block until the JS Promise resolves. This is complex and can cause deadlocks since the JS thread is blocked by the FFI call.

**Approach C: Run FFI call on background thread**

Run the entire FFI call on a background thread. The store callbacks would need to dispatch to the JS thread (via CallInvoker), wait for the response, and return. This is the pattern used by the Node.js NAPI bridge but is significantly more complex to implement.

---

## Reference: How the Upstream Rust Bridge Defines These Functions

From `rust/bridge/shared/src/protocol.rs` (lines ~520-560 in the upstream signalapp/libsignal repo):

```rust
#[bridge_fn(jni = "GroupSessionBuilder_1CreateSenderKeyDistributionMessage")]
async fn SenderKeyDistributionMessage_Create(
    sender: &ProtocolAddress,
    distribution_id: Uuid,
    store: &mut dyn SenderKeyStore,
) -> Result<SenderKeyDistributionMessage> {
    let mut csprng = rand::rngs::OsRng.unwrap_err();
    create_sender_key_distribution_message(sender, distribution_id, store, &mut csprng).await
}

#[bridge_fn(ffi = "process_sender_key_distribution_message",
            jni = "GroupSessionBuilder_1ProcessSenderKeyDistributionMessage")]
async fn SenderKeyDistributionMessage_Process(
    sender: &ProtocolAddress,
    sender_key_distribution_message: &SenderKeyDistributionMessage,
    store: &mut dyn SenderKeyStore,
) -> Result<()> {
    process_sender_key_distribution_message(sender, sender_key_distribution_message, store).await
}

#[bridge_fn(ffi = "group_encrypt_message")]
async fn GroupCipher_EncryptMessage(
    sender: &ProtocolAddress,
    distribution_id: Uuid,
    message: &[u8],
    store: &mut dyn SenderKeyStore,
) -> Result<CiphertextMessage> {
    let mut rng = rand::rngs::OsRng.unwrap_err();
    let ctext = group_encrypt(store, sender, distribution_id, message, &mut rng).await?;
    Ok(CiphertextMessage::SenderKeyMessage(ctext))
}

#[bridge_fn(ffi = "group_decrypt_message")]
async fn GroupCipher_DecryptMessage(
    sender: &ProtocolAddress,
    message: &[u8],
    store: &mut dyn SenderKeyStore,
) -> Result<Vec<u8>> {
    group_decrypt(message, store, sender).await
}
```

### What the Rust Code Does Internally

From `rust/protocol/src/group_cipher.rs`:

**`create_sender_key_distribution_message`**:
1. Calls `store.load_sender_key(sender, distribution_id)` to get existing SenderKeyRecord
2. If no record exists, creates new one with random chain key and signing key pair
3. Calls `store.store_sender_key(sender, distribution_id, record)` to persist
4. Returns a new `SenderKeyDistributionMessage` containing chain ID, iteration, chain key, and signing public key

**`process_sender_key_distribution_message`**:
1. Calls `store.load_sender_key(sender, distribution_id)` to get existing record (or creates empty)
2. Adds a new state to the record from the SKDM data (chain key, chain ID, iteration, signing key)
3. Calls `store.store_sender_key(sender, distribution_id, record)` to persist

**`group_encrypt`**:
1. Calls `store.load_sender_key(sender, distribution_id)` to get the SenderKeyRecord
2. Finds the sender's chain state, advances the chain key (HMAC-SHA256 ratchet)
3. Derives message key via HKDF, encrypts plaintext with AES-256-CBC
4. Signs the SenderKeyMessage with Ed25519
5. Calls `store.store_sender_key(sender, distribution_id, record)` to persist updated state
6. Returns a CiphertextMessage wrapping the SenderKeyMessage

**`group_decrypt`**:
1. Deserializes the SenderKeyMessage
2. Calls `store.load_sender_key(sender, distribution_id)` to find the matching chain state
3. Verifies the Ed25519 signature
4. Ratchets chain key forward to the correct iteration
5. Derives message key via HKDF, decrypts ciphertext with AES-256-CBC
6. Calls `store.store_sender_key(sender, distribution_id, record)` to persist updated state
7. Returns decrypted plaintext

---

## Reference: How Node.js NAPI Handles This

The Node.js addon (`signalapp/libsignal/node/`) uses NAPI's native async support:

1. The Rust `#[bridge_fn]` macro generates NAPI bindings that accept JavaScript objects implementing the store interface
2. NAPI can call JavaScript functions from Rust async contexts using `napi::threadsafe_function`
3. The Rust async runtime (`tokio`) runs the store operations, calling back into JS when needed
4. Results are returned via Node.js Promises

The React Native C++ port needs to achieve the same thing but through JSI instead of NAPI. The key difference is that JSI calls must happen on the JS thread (enforced by the runtime), while NAPI has built-in thread-safe function support.

---

## Reference: Existing Patterns in the RN Library

### Auto-generated Sync Functions (working)

The `gen_jsi_bindings.py` already generates bindings for synchronous functions like:
- `SenderKeyRecord_Serialize` / `SenderKeyRecord_Deserialize`
- `SenderKeyMessage_New` / `SenderKeyMessage_GetCipherText` / etc.
- `SenderKeyDistributionMessage_New` / `SenderKeyDistributionMessage_GetChainKey` / etc.
- `ProtocolAddress_New` / `ProtocolAddress_Name` / `ProtocolAddress_DeviceId`

### Auto-generated Async Functions (working)

The generator handles CPromise-based async functions using a completion callback pattern (see `gen_jsi_bindings.py` lines 1023-1100). These functions take a `SignalCPromise*` parameter with a `complete` callback that's invoked from a background thread, and results are marshaled back via `CallInvoker`.

However, the 4 missing functions don't use CPromise — they use synchronous C FFI with callback struct parameters.

---

## Files to Modify

1. **`cpp/generated_jsi_bindings.cpp`** or new file **`cpp/sender_key_store_bindings.cpp`**
   - Add hand-written JSI bindings for the 4 functions
   - Implement `JsiSenderKeyStoreContext` struct
   - Implement C callback functions for `load_sender_key` and `store_sender_key`

2. **`cpp/LibsignalTurboModule.cpp`** (if adding to existing registration)
   - Register the 4 new functions in the `functions_` map

3. **`lib/Native.js`** (no changes needed)
   - Line 34 already destructures these 4 names
   - Lines 208-211 already re-export them
   - Once the C++ bindings provide them, they'll automatically be available

4. **`scripts/gen_jsi_bindings.py`** (optional)
   - Could add support for `callback_struct` parameter type so future similar functions are auto-generated
   - Or just leave the 4 as hand-written and document the pattern

---

## Testing

Once implemented, the functions can be verified:

```typescript
import {
    SenderKeyDistributionMessage_Create,
    SenderKeyDistributionMessage_Process,
    GroupCipher_EncryptMessage,
    GroupCipher_DecryptMessage,
    ProtocolAddress_New,
    SenderKeyRecord_Serialize,
    SenderKeyRecord_Deserialize,
} from '@aspect-build/react-native-libsignal';

// Simple in-memory SenderKeyStore for testing
const store = {
    _records: new Map<string, Uint8Array>(),
    _getSenderKey(sender, distributionId) {
        const key = `${ProtocolAddress_Name(sender)}::${distributionId}`;
        const data = this._records.get(key);
        return data ? SenderKeyRecord_Deserialize(data) : null;
    },
    _saveSenderKey(sender, distributionId, record) {
        const key = `${ProtocolAddress_Name(sender)}::${distributionId}`;
        this._records.set(key, SenderKeyRecord_Serialize(record));
    },
};

// Test: Create SKDM
const sender = ProtocolAddress_New("alice", 1);
const distId = /* random UUID bytes */;
const skdm = await SenderKeyDistributionMessage_Create(sender, distId, store);
console.log("SKDM created:", skdm != null);

// Test: Process SKDM (on receiver side)
const receiver = ProtocolAddress_New("alice", 1); // Same sender address
const receiverStore = { /* similar store */ };
await SenderKeyDistributionMessage_Process(receiver, skdm, receiverStore);

// Test: Encrypt
const plaintext = new TextEncoder().encode("Hello, group!");
const ciphertext = await GroupCipher_EncryptMessage(sender, distId, plaintext, store);

// Test: Decrypt
const decrypted = await GroupCipher_DecryptMessage(receiver, ciphertext.serialize(), receiverStore);
console.log("Decrypted:", new TextDecoder().decode(decrypted));
```

---

## Priority

**CRITICAL** — These 4 functions are the only blockers preventing end-to-end encrypted group messaging from working. All other libsignal JSI bindings (444 functions) are working correctly. The consuming application has the full encryption pipeline built and tested with mocks, waiting only for these native functions.
