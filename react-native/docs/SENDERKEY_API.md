# SenderKey / Group Messaging API — React Native libsignal

This document describes the newly implemented SenderKey (group messaging) functions available in the React Native libsignal bindings. These are low-level JSI bindings exposed on the `__libsignal_native` global object.

## Overview

Group messaging in Signal Protocol uses **SenderKey** distribution. The flow is:

1. **Create** a `SenderKeyDistributionMessage` (SKDM) for a group — this generates a new sender key and stores it locally.
2. **Distribute** the serialized SKDM to every group member (out of band, e.g. via 1:1 encrypted message).
3. Each recipient **processes** the SKDM — this stores the sender's key in their local store.
4. The sender **encrypts** messages using `GroupCipher_EncryptMessage`.
5. Each recipient **decrypts** using `GroupCipher_DecryptMessage`.

## SenderKeyStore Interface

All four functions require a **SenderKeyStore** object. This is a plain JS object with two synchronous methods:

```typescript
interface SenderKeyStore {
  /**
   * Load a sender key record for the given (sender, distributionId) pair.
   * @param sender - NativePointer to a ProtocolAddress (use ProtocolAddress_Name / ProtocolAddress_DeviceId to inspect)
   * @param distributionId - Uint8Array (16 bytes, UUID)
   * @returns NativePointer to a SenderKeyRecord, or null if not found
   */
  _getSenderKey(sender: NativePointer, distributionId: Uint8Array): NativePointer | null;

  /**
   * Store a sender key record for the given (sender, distributionId) pair.
   * @param sender - NativePointer to a ProtocolAddress
   * @param distributionId - Uint8Array (16 bytes, UUID)
   * @param record - NativePointer to a SenderKeyRecord (owned — store will control its lifetime)
   */
  _saveSenderKey(sender: NativePointer, distributionId: Uint8Array, record: NativePointer): void;
}
```

### Important Notes on the Store

- Both methods are called **synchronously** from native code during FFI calls. They must **not** return Promises.
- The `sender` NativePointer passed to callbacks is **borrowed** — do not store it beyond the callback's lifetime. If you need the address identity, extract name/deviceId immediately:
  ```typescript
  const name = __libsignal_native.ProtocolAddress_Name(sender);
  const deviceId = __libsignal_native.ProtocolAddress_DeviceId(sender);
  ```
- The `record` NativePointer passed to `_saveSenderKey` is **owned** by the store — keep a reference to it for later retrieval via `_getSenderKey`.
- The `distributionId` is a 16-byte UUID as a `Uint8Array`.

### Example In-Memory Store

```typescript
function createSenderKeyStore() {
  const records = new Map<string, any>();

  function makeKey(sender: any, distributionId: Uint8Array): string {
    const name = __libsignal_native.ProtocolAddress_Name(sender);
    const deviceId = __libsignal_native.ProtocolAddress_DeviceId(sender);
    const idHex = Array.from(distributionId)
      .map((b: number) => b.toString(16).padStart(2, '0'))
      .join('');
    return `${name}:${deviceId}:${idHex}`;
  }

  return {
    _getSenderKey(sender: any, distributionId: Uint8Array): any {
      const key = makeKey(sender, distributionId);
      return records.get(key) || null;
    },
    _saveSenderKey(sender: any, distributionId: Uint8Array, record: any): void {
      const key = makeKey(sender, distributionId);
      records.set(key, record);
    },
  };
}
```

## Functions

### `SenderKeyDistributionMessage_Create(sender, distributionId, store)`

Creates a new SenderKeyDistributionMessage. This generates a new sender key (or updates an existing one) in the store.

| Parameter | Type | Description |
|-----------|------|-------------|
| `sender` | `NativePointer` | ProtocolAddress of the sender (from `ProtocolAddress_New`) |
| `distributionId` | `Uint8Array` | 16-byte UUID identifying the distribution group |
| `store` | `SenderKeyStore` | Object implementing `_getSenderKey` and `_saveSenderKey` |

**Returns:** `NativePointer` — handle to a `SenderKeyDistributionMessage`. Serialize it with `SenderKeyDistributionMessage_Serialize()` for transmission.

```typescript
const sender = __libsignal_native.ProtocolAddress_New('+14155550100', 1);
const distributionId = new Uint8Array(16); // your group UUID
const store = createSenderKeyStore();

const skdm = __libsignal_native.SenderKeyDistributionMessage_Create(
  sender, distributionId, store
);
const serialized = __libsignal_native.SenderKeyDistributionMessage_Serialize(skdm);
// Send `serialized` to group members via encrypted 1:1 channel
```

---

### `SenderKeyDistributionMessage_Process(sender, skdm, store)`

Processes a received SenderKeyDistributionMessage, storing the sender's key.

| Parameter | Type | Description |
|-----------|------|-------------|
| `sender` | `NativePointer` | ProtocolAddress of the sender who created the SKDM |
| `skdm` | `NativePointer` | The SenderKeyDistributionMessage handle (from `SenderKeyDistributionMessage_Deserialize`) |
| `store` | `SenderKeyStore` | Receiver's SenderKeyStore |

**Returns:** `undefined`

```typescript
// Receiver side — after receiving serialized SKDM bytes
const skdm = __libsignal_native.SenderKeyDistributionMessage_Deserialize(receivedBytes);
__libsignal_native.SenderKeyDistributionMessage_Process(senderAddress, skdm, myStore);
```

---

### `GroupCipher_EncryptMessage(sender, distributionId, message, store)`

Encrypts a plaintext message for the group.

| Parameter | Type | Description |
|-----------|------|-------------|
| `sender` | `NativePointer` | ProtocolAddress of the sender (must match the SKDM creator) |
| `distributionId` | `Uint8Array` | 16-byte group UUID (must match the SKDM) |
| `message` | `Uint8Array` | Plaintext message bytes |
| `store` | `SenderKeyStore` | Sender's SenderKeyStore (must contain the key from `SenderKeyDistributionMessage_Create`) |

**Returns:** `NativePointer` — handle to a `CiphertextMessage`. Serialize with `CiphertextMessage_Serialize()`.

```typescript
const plaintext = new TextEncoder().encode('Hello group!');
const ciphertext = __libsignal_native.GroupCipher_EncryptMessage(
  sender, distributionId, plaintext, senderStore
);
const encrypted = __libsignal_native.CiphertextMessage_Serialize(ciphertext);
// Broadcast `encrypted` to group members
```

---

### `GroupCipher_DecryptMessage(sender, message, store)`

Decrypts a group message.

| Parameter | Type | Description |
|-----------|------|-------------|
| `sender` | `NativePointer` | ProtocolAddress of the message sender |
| `message` | `Uint8Array` | Serialized ciphertext bytes (from `CiphertextMessage_Serialize`) |
| `store` | `SenderKeyStore` | Receiver's SenderKeyStore (must have processed the sender's SKDM) |

**Returns:** `Uint8Array` — the decrypted plaintext bytes.

```typescript
const decrypted = __libsignal_native.GroupCipher_DecryptMessage(
  senderAddress, encryptedBytes, receiverStore
);
const text = new TextDecoder().decode(decrypted);
```

---

## Complete Example: Group Messaging Round-Trip

```typescript
// Setup
const alice = __libsignal_native.ProtocolAddress_New('alice', 1);
const distributionId = crypto.getRandomValues(new Uint8Array(16));
const aliceStore = createSenderKeyStore();
const bobStore = createSenderKeyStore();

// 1. Alice creates SKDM
const skdm = __libsignal_native.SenderKeyDistributionMessage_Create(
  alice, distributionId, aliceStore
);

// 2. Serialize and send to Bob (simulated)
const skdmBytes = __libsignal_native.SenderKeyDistributionMessage_Serialize(skdm);

// 3. Bob processes the SKDM
const receivedSkdm = __libsignal_native.SenderKeyDistributionMessage_Deserialize(skdmBytes);
__libsignal_native.SenderKeyDistributionMessage_Process(alice, receivedSkdm, bobStore);

// 4. Alice encrypts a message
const plaintext = new Uint8Array([72, 101, 108, 108, 111]); // "Hello"
const ciphertext = __libsignal_native.GroupCipher_EncryptMessage(
  alice, distributionId, plaintext, aliceStore
);
const encrypted = __libsignal_native.CiphertextMessage_Serialize(ciphertext);

// 5. Bob decrypts
const decrypted = __libsignal_native.GroupCipher_DecryptMessage(
  alice, encrypted, bobStore
);
// decrypted is Uint8Array [72, 101, 108, 108, 111]
```

## Error Handling

All functions throw a JSI error (catchable as a standard JS `Error`) if the underlying libsignal operation fails. Common failure modes:

- **No sender key in store**: `GroupCipher_EncryptMessage` will fail if `SenderKeyDistributionMessage_Create` hasn't been called first for that (sender, distributionId).
- **SKDM not processed**: `GroupCipher_DecryptMessage` will fail if the receiver hasn't processed the sender's SKDM.
- **Message replay / out-of-order**: The protocol tracks message chains; heavily out-of-order messages may fail to decrypt.
- **Store callback errors**: If `_getSenderKey` or `_saveSenderKey` throw an exception, the FFI call will fail with a generic error.

## Related Auto-Generated Functions

These functions were already available via the auto-generated bindings and are used alongside the new SenderKey functions:

| Function | Description |
|----------|-------------|
| `ProtocolAddress_New(name, deviceId)` | Create a ProtocolAddress |
| `SenderKeyDistributionMessage_Serialize(skdm)` | Serialize SKDM to bytes |
| `SenderKeyDistributionMessage_Deserialize(bytes)` | Deserialize SKDM from bytes |
| `CiphertextMessage_Serialize(ct)` | Serialize ciphertext to bytes |
| `ProtocolAddress_Name(addr)` | Get name from ProtocolAddress |
| `ProtocolAddress_DeviceId(addr)` | Get device ID from ProtocolAddress |
