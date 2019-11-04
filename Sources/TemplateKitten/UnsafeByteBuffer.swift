import NIO
import Dispatch

@inlinable func _toCapacity(_ value: Int) -> ByteBuffer._Capacity {
    return UnsafeByteBuffer._Capacity(truncatingIfNeeded: value)
}

@inlinable func _toIndex(_ value: Int) -> ByteBuffer._Index {
    return UnsafeByteBuffer._Index(truncatingIfNeeded: value)
}

public struct UnsafeByteBuffer {
    public typealias _Index = UInt32
    public typealias _Capacity = UInt32

    @usableFromInline let _storage: UnsafeRawPointer
    @usableFromInline var _readerIndex: _Index = 0
    @usableFromInline var _capacity: _Index
    
    @inlinable
    public init(pointer: UnsafeRawPointer, size: Int) {
        self._storage = pointer
        self._capacity = _toCapacity(size)
    }
    
    @inlinable
    mutating func _moveReaderIndex(to newIndex: _Index) {
        assert(newIndex >= 0 && newIndex <= _capacity)
        self._readerIndex = newIndex
    }

    @inlinable
    mutating func _moveReaderIndex(forwardBy offset: Int) {
        let newIndex = self._readerIndex + _toIndex(offset)
        self._moveReaderIndex(to: newIndex)
    }
    
    public mutating func moveReaderIndex(forwardBy offset: Int) {
        let newIndex = self._readerIndex + _toIndex(offset)
        precondition(newIndex >= 0 && newIndex <= _capacity, "new readerIndex: \(newIndex), expected: range(0, \(_capacity))")
        self._moveReaderIndex(to: newIndex)
    }
    
    public mutating func moveReaderIndex(to offset: Int) {
        let newIndex = _toIndex(offset)
        precondition(newIndex >= 0 && newIndex <= _capacity, "new readerIndex: \(newIndex), expected: range(0, \(_capacity))")
        self._moveReaderIndex(to: newIndex)
    }
    
    public var readerIndex: Int {
        return Int(self._readerIndex)
    }
    
    public var capacity: Int {
        return Int(_capacity)
    }
    
    public var readableBytes: Int { return Int(self._capacity - self._readerIndex) }
    
    public func getUnsafeSlice(at index: Int, length: Int) -> UnsafeByteBuffer? {
        guard index >= 0 && length >= 0 && index >= self.readerIndex && index <= capacity - length else {
            return nil
        }
        
        return UnsafeByteBuffer(pointer: _storage + index, size: length)
    }
    
    public mutating func readUnsafeSlice(length: Int) -> UnsafeByteBuffer? {
        return getUnsafeSlice(at: self.readerIndex, length: length).map {
            self._moveReaderIndex(forwardBy: length)
            return $0
        }
    }
    
    @inlinable
    public func withUnsafeReadableBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
        return try body(.init(start: _storage + readerIndex, count: self.readableBytes))
    }
    
    public func getBytes(at index: Int, length: Int) -> [UInt8]? {
        guard let range = self.rangeWithinReadableBytes(index: index, length: length) else {
            return nil
        }

        return self.withUnsafeReadableBytes { ptr in
            // this is not technically correct because we shouldn't just bind
            // the memory to `UInt8` but it's not a real issue either and we
            // need to work around https://bugs.swift.org/browse/SR-9604
            Array<UInt8>(UnsafeRawBufferPointer(rebasing: ptr[range]).bindMemory(to: UInt8.self))
        }
    }
    
    public mutating func readBytes(length: Int) -> [UInt8]? {
        return self.getBytes(at: self.readerIndex, length: length).map {
            self._moveReaderIndex(forwardBy: length)
            return $0
        }
    }
    
    public func getString(at index: Int, length: Int) -> String? {
        guard let range = self.rangeWithinReadableBytes(index: index, length: length) else {
            return nil
        }
        return self.withUnsafeReadableBytes { pointer in
            assert(range.lowerBound >= 0 && (range.upperBound - range.lowerBound) <= pointer.count)
            return String(decoding: UnsafeRawBufferPointer(rebasing: pointer[range]), as: Unicode.UTF8.self)
        }
    }
    
    public mutating func readString(length: Int) -> String? {
        return self.getString(at: self.readerIndex, length: length).map {
            self._moveReaderIndex(forwardBy: length)
            return $0
        }
    }
    
    public func getDispatchData(at index: Int, length: Int) -> DispatchData? {
        guard let range = self.rangeWithinReadableBytes(index: index, length: length) else {
            return nil
        }
        return self.withUnsafeReadableBytes { pointer in
            return DispatchData(bytes: UnsafeRawBufferPointer(rebasing: pointer[range]))
        }
    }
    
    public mutating func readDispatchData(length: Int) -> DispatchData? {
        return self.getDispatchData(at: self.readerIndex, length: length).map {
            self._moveReaderIndex(forwardBy: length)
            return $0
        }
    }
    
    @discardableResult
    @inlinable
    public mutating func readWithUnsafeReadableBytes(_ body: (UnsafeRawBufferPointer) throws -> Int) rethrows -> Int {
        let bytesRead = try self.withUnsafeReadableBytes(body)
        self._moveReaderIndex(forwardBy: bytesRead)
        return bytesRead
    }
    
    @inlinable
    public mutating func readWithUnsafeReadableBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> (Int, T)) rethrows -> T {
        let (bytesRead, ret) = try self.withUnsafeReadableBytes(body)
        self._moveReaderIndex(forwardBy: bytesRead)
        return ret
    }
    
    @inlinable
    func _toEndianness<T: FixedWidthInteger> (value: T, endianness: Endianness) -> T {
        switch endianness {
        case .little:
            return value.littleEndian
        case .big:
            return value.bigEndian
        }
    }

    /// Read an integer off this `ByteBuffer`, move the reader index forward by the integer's byte size and return the result.
    ///
    /// - parameters:
    ///     - endianness: The endianness of the integer in this `ByteBuffer` (defaults to big endian).
    ///     - as: the desired `FixedWidthInteger` type (optional parameter)
    /// - returns: An integer value deserialized from this `ByteBuffer` or `nil` if there aren't enough bytes readable.
    @inlinable
    public mutating func readInteger<T: FixedWidthInteger>(endianness: Endianness = .little, as: T.Type = T.self) -> T? {
        return self.getInteger(at: self.readerIndex, endianness: endianness, as: T.self).map {
            self._moveReaderIndex(forwardBy: MemoryLayout<T>.size)
            return $0
        }
    }

    /// Get the integer at `index` from this `ByteBuffer`. Does not move the reader index.
    /// The selected bytes must be readable or else `nil` will be returned.
    ///
    /// - parameters:
    ///     - index: The starting index of the bytes for the integer into the `ByteBuffer`.
    ///     - endianness: The endianness of the integer in this `ByteBuffer` (defaults to big endian).
    ///     - as: the desired `FixedWidthInteger` type (optional parameter)
    /// - returns: An integer value deserialized from this `ByteBuffer` or `nil` if the bytes of interest are not
    ///            readable.
    @inlinable
    public func getInteger<T: FixedWidthInteger>(at index: Int, endianness: Endianness = .little, as: T.Type = T.self) -> T? {
        guard let range = self.rangeWithinReadableBytes(index: index, length: MemoryLayout<T>.size) else {
            return nil
        }
        
        let value = self._storage.advanced(by: index).bindMemory(to: T.self, capacity: 1).pointee
        return _toEndianness(value: value, endianness: endianness)
    }
}

extension UnsafeByteBuffer {
    @inlinable
    func rangeWithinReadableBytes(index: Int, length: Int) -> Range<Int>? {
        let indexFromReaderIndex = index - self.readerIndex
        guard indexFromReaderIndex >= 0 && length >= 0 && indexFromReaderIndex <= self.readableBytes - length else {
            return nil
        }
        return indexFromReaderIndex ..< (indexFromReaderIndex+length)
    }
}
