/*
 * Copyright 2020 Google Inc. All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Foundation

public struct ByteBuffer {

  /// Storage is a container that would hold the memory pointer to solve the issue of
  /// deallocating the memory that was held by (memory: UnsafeMutableRawPointer)
  @usableFromInline
  final class Storage {
    // This storage doesn't own the memory, therefore, we won't deallocate on deinit.
    private let unowned: Bool
    /// pointer to the start of the buffer object in memory
    var memory: UnsafeMutableRawPointer
    /// Capacity of UInt8 the buffer can hold
    var capacity: Int

    init(count: Int, alignment: Int) {
      memory = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: alignment)
      capacity = count
      unowned = false
    }

    init(memory: UnsafeMutableRawPointer, capacity: Int, unowned: Bool) {
      self.memory = memory
      self.capacity = capacity
      self.unowned = unowned
    }

    deinit {
      if !unowned {
        memory.deallocate()
      }
    }

    func copy(from ptr: UnsafeRawPointer, count: Int) {
      assert(
        !unowned,
        "copy should NOT be called on a buffer that is built by assumingMemoryBound")
      memory.copyMemory(from: ptr, byteCount: count)
    }

    func initialize(for size: Int) {
      assert(
        !unowned,
        "initalize should NOT be called on a buffer that is built by assumingMemoryBound")
      memset(memory, 0, size)
    }

    /// Reallocates the buffer incase the object to be written doesnt fit in the current buffer
    /// - Parameter size: Size of the current object
    @usableFromInline
    internal func reallocate(_ size: Int, writerSize: Int, alignment: Int) {
      let currentWritingIndex = capacity &- writerSize
      while capacity <= writerSize &+ size {
        capacity = capacity << 1
      }

      /// solution take from Apple-NIO
      capacity = capacity.convertToPowerofTwo

      let newData = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: alignment)
      memset(newData, 0, capacity &- writerSize)
      memcpy(
        newData.advanced(by: capacity &- writerSize),
        memory.advanced(by: currentWritingIndex),
        writerSize)
      memory.deallocate()
      memory = newData
    }
  }

  @usableFromInline var _storage: Storage

  /// The size of the elements written to the buffer + their paddings
  private var _writerSize: Int = 0
  /// Aliginment of the current  memory being written to the buffer
  internal var alignment = 1
  /// Current Index which is being used to write to the buffer, it is written from the end to the start of the buffer
  internal var writerIndex: Int { _storage.capacity &- _writerSize }

  /// Reader is the position of the current Writer Index (capacity - size)
  public var reader: Int { writerIndex }
  /// Current size of the buffer
  public var size: UOffset { UOffset(_writerSize) }
  /// Public Pointer to the buffer object in memory. This should NOT be modified for any reason
  public var memory: UnsafeMutableRawPointer { _storage.memory }
  /// Current capacity for the buffer
  public var capacity: Int { _storage.capacity }

  /// Constructor that creates a Flatbuffer object from a UInt8
  /// - Parameter bytes: Array of UInt8
  public init(bytes: [UInt8]) {
    var b = bytes
    _storage = Storage(count: bytes.count, alignment: alignment)
    _writerSize = _storage.capacity
    b.withUnsafeMutableBytes { bufferPointer in
      self._storage.copy(from: bufferPointer.baseAddress!, count: bytes.count)
    }
  }

  /// Constructor that creates a Flatbuffer from the Swift Data type object
  /// - Parameter data: Swift data Object
  public init(data: Data) {
    var b = data
    _storage = Storage(count: data.count, alignment: alignment)
    _writerSize = _storage.capacity
    b.withUnsafeMutableBytes { bufferPointer in
      self._storage.copy(from: bufferPointer.baseAddress!, count: data.count)
    }
  }

  /// Constructor that creates a Flatbuffer instance with a size
  /// - Parameter size: Length of the buffer
  init(initialSize size: Int) {
    let size = size.convertToPowerofTwo
    _storage = Storage(count: size, alignment: alignment)
    _storage.initialize(for: size)
  }

  #if swift(>=5.0)
  /// Constructor that creates a Flatbuffer object from a ContiguousBytes
  /// - Parameters:
  ///   - contiguousBytes: Binary stripe to use as the buffer
  ///   - count: amount of readable bytes
  public init<Bytes: ContiguousBytes>(
    contiguousBytes: Bytes,
    count: Int)
  {
    _storage = Storage(count: count, alignment: alignment)
    _writerSize = _storage.capacity
    contiguousBytes.withUnsafeBytes { buf in
      _storage.copy(from: buf.baseAddress!, count: buf.count)
    }
  }
  #endif

  /// Constructor that creates a Flatbuffer from unsafe memory region without copying
  /// - Parameter assumingMemoryBound: The unsafe memory region
  /// - Parameter capacity: The size of the given memory region
  public init(assumingMemoryBound memory: UnsafeMutableRawPointer, capacity: Int) {
    _storage = Storage(memory: memory, capacity: capacity, unowned: true)
    _writerSize = capacity
  }

  /// Creates a copy of the buffer that's being built by calling sizedBuffer
  /// - Parameters:
  ///   - memory: Current memory of the buffer
  ///   - count: count of bytes
  internal init(memory: UnsafeMutableRawPointer, count: Int) {
    _storage = Storage(count: count, alignment: alignment)
    _storage.copy(from: memory, count: count)
    _writerSize = _storage.capacity
  }

  /// Creates a copy of the existing flatbuffer, by copying it to a different memory.
  /// - Parameters:
  ///   - memory: Current memory of the buffer
  ///   - count: count of bytes
  ///   - removeBytes: Removes a number of bytes from the current size
  internal init(memory: UnsafeMutableRawPointer, count: Int, removing removeBytes: Int) {
    _storage = Storage(count: count, alignment: alignment)
    _storage.copy(from: memory, count: count)
    _writerSize = removeBytes
  }

  /// Fills the buffer with padding by adding to the writersize
  /// - Parameter padding: Amount of padding between two to be serialized objects
  @usableFromInline
  mutating func fill(padding: Int) {
    assert(padding >= 0, "Fill should be larger than or equal to zero")
    ensureSpace(size: padding)
    _writerSize = _writerSize &+ (MemoryLayout<UInt8>.size &* padding)
  }

  ///Adds an array of type Scalar to the buffer memory
  /// - Parameter elements: An array of Scalars
  @usableFromInline
  mutating func push<T: Scalar>(elements: [T]) {
    let size = elements.count &* MemoryLayout<T>.size
    ensureSpace(size: size)
    elements.reversed().forEach { s in
      push(value: s, len: MemoryLayout.size(ofValue: s))
    }
  }

  /// A custom type of structs that are padded according to the flatbuffer padding,
  /// - Parameters:
  ///   - value: Pointer to the object in memory
  ///   - size: Size of Value being written to the buffer
  @available(
    *,
    deprecated,
    message: "0.9.0 will be removing the following method. Regenerate the code")
  @usableFromInline
  mutating func push(struct value: UnsafeMutableRawPointer, size: Int) {
    ensureSpace(size: size)
    memcpy(_storage.memory.advanced(by: writerIndex &- size), value, size)
    defer { value.deallocate() }
    _writerSize = _writerSize &+ size
  }

  /// Prepares the buffer to receive a struct of certian size.
  /// The alignment of the memory is already handled since we already called preAlign
  /// - Parameter size: size of the struct
  @usableFromInline
  mutating func prepareBufferToReceiveStruct(of size: Int) {
    ensureSpace(size: size)
    _writerSize = _writerSize &+ size
  }

  /// Reverse the input direction to the buffer, since `FlatBuffers` uses a back to front, following method will take current `writerIndex`
  /// and writes front to back into the buffer, respecting the padding & the alignment
  /// - Parameters:
  ///   - value: value of type Scalar
  ///   - position: position relative to the `writerIndex`
  ///   - len: length of the value in terms of bytes
  @usableFromInline
  mutating func reversePush<T: Scalar>(value: T, position: Int, len: Int) {
    var v = value
    memcpy(_storage.memory.advanced(by: writerIndex &+ position), &v, len)
  }

  /// Adds an object of type Scalar into the buffer
  /// - Parameters:
  ///   - value: Object  that will be written to the buffer
  ///   - len: Offset to subtract from the WriterIndex
  @usableFromInline
  mutating func push<T: Scalar>(value: T, len: Int) {
    ensureSpace(size: len)
    var v = value
    memcpy(_storage.memory.advanced(by: writerIndex &- len), &v, len)
    _writerSize = _writerSize &+ len
  }

  /// Adds a string to the buffer using swift.utf8 object
  /// - Parameter str: String that will be added to the buffer
  /// - Parameter len: length of the string
  @usableFromInline
  mutating func push(string str: String, len: Int) {
    ensureSpace(size: len)
    if str.utf8.withContiguousStorageIfAvailable({ self.push(bytes: $0, len: len) }) != nil {
    } else {
      let utf8View = str.utf8
      for c in utf8View.reversed() {
        push(value: c, len: 1)
      }
    }
  }

  /// Writes a string to Bytebuffer using UTF8View
  /// - Parameters:
  ///   - bytes: Pointer to the view
  ///   - len: Size of string
  @usableFromInline
  mutating internal func push(
    bytes: UnsafeBufferPointer<String.UTF8View.Element>,
    len: Int) -> Bool
  {
    memcpy(
      _storage.memory.advanced(by: writerIndex &- len),
      UnsafeRawPointer(bytes.baseAddress!),
      len)
    _writerSize = _writerSize &+ len
    return true
  }

  /// Write stores an object into the buffer directly or indirectly.
  ///
  /// Direct: ignores the capacity of buffer which would mean we are referring to the direct point in memory
  /// indirect: takes into respect the current capacity of the buffer (capacity - index), writing to the buffer from the end
  /// - Parameters:
  ///   - value: Value that needs to be written to the buffer
  ///   - index: index to write to
  ///   - direct: Should take into consideration the capacity of the buffer
  func write<T>(value: T, index: Int, direct: Bool = false) {
    var index = index
    if !direct {
      index = _storage.capacity &- index
    }
    assert(index < _storage.capacity, "Write index is out of writing bound")
    assert(index >= 0, "Writer index should be above zero")
    _storage.memory.storeBytes(of: value, toByteOffset: index, as: T.self)
  }

  /// Makes sure that buffer has enouch space for each of the objects that will be written into it
  /// - Parameter size: size of object
  @discardableResult
  @usableFromInline
  mutating func ensureSpace(size: Int) -> Int {
    if size &+ _writerSize > _storage.capacity {
      _storage.reallocate(size, writerSize: _writerSize, alignment: alignment)
    }
    assert(size < FlatBufferMaxSize, "Buffer can't grow beyond 2 Gigabytes")
    return size
  }

  /// pops the written VTable if it's already written into the buffer
  /// - Parameter size: size of the `VTable`
  @usableFromInline
  mutating internal func pop(_ size: Int) {
    assert((_writerSize &- size) > 0, "New size should NOT be a negative number")
    memset(_storage.memory.advanced(by: writerIndex), 0, _writerSize &- size)
    _writerSize = size
  }

  /// Clears the current size of the buffer
  mutating public func clearSize() {
    _writerSize = 0
  }

  /// Clears the current instance of the buffer, replacing it with new memory
  mutating public func clear() {
    _writerSize = 0
    alignment = 1
    _storage.initialize(for: _storage.capacity)
  }

  /// Reads an object from the buffer
  /// - Parameters:
  ///   - def: Type of the object
  ///   - position: the index of the object in the buffer
  public func read<T>(def: T.Type, position: Int) -> T {
    assert(
      position + MemoryLayout<T>.size <= _storage.capacity,
      "Reading out of bounds is illegal")
    return _storage.memory.advanced(by: position).load(as: T.self)
  }

  /// Reads a slice from the memory assuming a type of T
  /// - Parameters:
  ///   - index: index of the object to be read from the buffer
  ///   - count: count of bytes in memory
  public func readSlice<T>(
    index: Int32,
    count: Int32) -> [T]
  {
    let _index = Int(index)
    let _count = Int(count)
    assert(_index + _count <= _storage.capacity, "Reading out of bounds is illegal")
    let start = _storage.memory.advanced(by: _index).assumingMemoryBound(to: T.self)
    let array = UnsafeBufferPointer(start: start, count: _count)
    return Array(array)
  }

  /// Reads a string from the buffer and encodes it to a swift string
  /// - Parameters:
  ///   - index: index of the string in the buffer
  ///   - count: length of the string
  ///   - type: Encoding of the string
  public func readString(
    at index: Int32,
    count: Int32,
    type: String.Encoding = .utf8) -> String?
  {
    let _index = Int(index)
    let _count = Int(count)
    assert(_index + _count <= _storage.capacity, "Reading out of bounds is illegal")
    let start = _storage.memory.advanced(by: _index).assumingMemoryBound(to: UInt8.self)
    let bufprt = UnsafeBufferPointer(start: start, count: _count)
    return String(bytes: Array(bufprt), encoding: type)
  }

  /// Creates a new Flatbuffer object that's duplicated from the current one
  /// - Parameter removeBytes: the amount of bytes to remove from the current Size
  public func duplicate(removing removeBytes: Int = 0) -> ByteBuffer {
    assert(removeBytes > 0, "Can NOT remove negative bytes")
    assert(removeBytes < _storage.capacity, "Can NOT remove more bytes than the ones allocated")
    return ByteBuffer(
      memory: _storage.memory,
      count: _storage.capacity,
      removing: _writerSize &- removeBytes)
  }
}

extension ByteBuffer: CustomDebugStringConvertible {

  public var debugDescription: String {
    """
    buffer located at: \(_storage.memory), with capacity of \(_storage.capacity)
    { writerSize: \(_writerSize), readerSize: \(reader), writerIndex: \(writerIndex) }
    """
  }
}
