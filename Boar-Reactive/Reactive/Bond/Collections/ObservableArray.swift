//
//  The MIT License (MIT)
//
//  Copyright (c) 2016 Srdan Rasic (@srdanrasic)
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

import Foundation

public enum ObservableArrayChange {
    case reset
    case inserts([Int])
    case deletes([Int])
    case updates([Int])
    case move(Int, Int)
    case beginBatchEditing
    case endBatchEditing
}

public protocol ObservableArrayEventProtocol {
    associatedtype Item
    var change: ObservableArrayChange { get }
    var source: [Item] { get }
}

public struct ObservableArrayEvent<Item>: ObservableArrayEventProtocol {
    public let change: ObservableArrayChange
    public let source: [Item]

    public init(change: ObservableArrayChange, source: [Item]) {
        self.change = change
        self.source = source
    }
}

public struct ObservableArrayPatchEvent<Item>: ObservableArrayEventProtocol {
    public let change: ObservableArrayChange
    public let source: [Item]

    public init(change: ObservableArrayChange, source: [Item]) {
        self.change = change
        self.source = source
    }
}

open class ObservableArrayBase<Item>: SignalProtocol {

    open var array: [Item]{
        get {
            fatalError("Don't use this class")
        }
    }
    public let subject = PublishSubject<ObservableArrayEvent<Item>>()
    
    public init() {
        
    }

    public func makeIterator() -> Array<Item>.Iterator {
        return array.makeIterator()
    }

    public var underestimatedCount: Int {
        return array.underestimatedCount
    }

    public var startIndex: Int {
        return array.startIndex
    }

    public var endIndex: Int {
        return array.endIndex
    }

    public func index(after i: Int) -> Int {
        return array.index(after: i)
    }

    public var isEmpty: Bool {
        return array.isEmpty
    }

    public var count: Int {
        return array.count
    }

    public subscript(index: Int) -> Item {
        get {
            return array[index]
        }
    }

    public func observe(with observer: @escaping (Event<ObservableArrayEvent<Item>>) -> Void) -> Disposable {
        observer(.next(ObservableArrayEvent(change: .reset, source: array)))
        return subject.observe(with: observer)
    }
}


public class ObservableArray<Item> : ObservableArrayBase<Item> {
    
    fileprivate var _array : [Item]
   
    
    override public var array: [Item] {
        return _array
    }
    
    public init(_ array: [Item] = []) {
        _array = array
        super.init()
    }
}

extension ObservableArrayBase: CustomDebugStringConvertible {

    public var debugDescription: String {
        return array.debugDescription
    }
}

extension ObservableArrayBase: Deallocatable {

    public var deallocated: Signal<Void> {
        return subject.bag.deallocated
    }
}

extension ObservableArrayBase where Item: Equatable {

    public static func ==(lhs: ObservableArrayBase<Item>, rhs: ObservableArrayBase<Item>) -> Bool {
        return lhs.array == rhs.array
    }
}

public class MutableObservableArray<Item>: ObservableArray<Item> {

    private let lock = NSRecursiveLock(name: "com.reactivekit.bond.observablearray")
    /// Append `newElement` to the array.
    public func append(_ newElement: Item) {
        lock.lock(); defer { lock.unlock() }
        _array.append(newElement)
        subject.next(ObservableArrayEvent(change: .inserts([array.count-1]), source: _array))
    }

    /// Insert `newElement` at index `i`.
    public func insert(_ newElement: Item, at index: Int)  {
        lock.lock(); defer { lock.unlock() }
        _array.insert(newElement, at: index)
        subject.next(ObservableArrayEvent(change: .inserts([index]), source: _array))
    }

    /// Insert elements `newElements` at index `i`.
    public func insert(contentsOf newElements: [Item], at index: Int) {
        lock.lock(); defer { lock.unlock() }
        _array.insert(contentsOf: newElements, at: index)
        subject.next(ObservableArrayEvent(change: .inserts(Array(index..<index+newElements.count)), source: _array))
    }

    /// Move the element at index `i` to index `toIndex`.
    public func moveItem(from fromIndex: Int, to toIndex: Int) {
        lock.lock(); defer { lock.unlock() }
        let item = _array.remove(at: fromIndex)
        _array.insert(item, at: toIndex)
        subject.next(ObservableArrayEvent(change: .move(fromIndex, toIndex), source: _array))
    }

    /// Remove and return the element at index i.
    @discardableResult
    public func remove(at index: Int) -> Item {
        lock.lock(); defer { lock.unlock() }
        let element = _array.remove(at: index)
        subject.next(ObservableArrayEvent(change: .deletes([index]), source: _array))
        return element
    }

    /// Remove an element from the end of the array in O(1).
    @discardableResult
    public func removeLast() -> Item {
        lock.lock(); defer { lock.unlock() }
        let element = _array.removeLast()
        subject.next(ObservableArrayEvent(change: .deletes([array.count]), source: _array))
        return element
    }

    /// Remove all elements from the array.
    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        let deletes = Array(0..<array.count)
        _array.removeAll()
        subject.next(ObservableArrayEvent(change: .deletes(deletes), source: _array))
    }

    public override subscript(index: Int) -> Item {
        get {
            return array[index]
        }
        set {
            lock.lock(); defer { lock.unlock() }
            _array[index] = newValue
            subject.next(ObservableArrayEvent(change: .updates([index]), source: _array))
        }
    }

    /// Perform batched updates on the array.
    public func batchUpdate(_ update: (MutableObservableArray<Item>) -> Void) {
        lock.lock(); defer { lock.unlock() }

        // use proxy to collect changes
        let proxy = MutableObservableArray(array)
        var patch: [ObservableArrayChange] = []
        let disposable = proxy.skip(first: 1).observeNext { event in
            patch.append(event.change)
        }
        update(proxy)
        disposable.dispose()

        // generate diff from changes
        let diff = generateDiff(from: patch)

        // if only reset, do not batch:
        if diff == [.reset] {
            _array = proxy.array
            subject.next(ObservableArrayEvent(change: .reset, source: _array))
        } else if diff.count > 0 {
            // ...otherwise batch:
            subject.next(ObservableArrayEvent(change: .beginBatchEditing, source: _array))
            _array = proxy.array
            diff.forEach { change in
                subject.next(ObservableArrayEvent(change: change, source: _array))
            }
            subject.next(ObservableArrayEvent(change: .endBatchEditing, source: _array))
        }
    }

    /// Change the underlying value withouth notifying the observers.
    public func silentUpdate(_ update: (inout [Item]) -> Void) {
        lock.lock(); defer { lock.unlock() }
        update(&_array)
    }
}

extension MutableObservableArray: BindableProtocol {

    public func bind(signal: Signal<ObservableArrayEvent<Item>>) -> Disposable {
        return signal
            .take(until: deallocated)
            .observeNext { [weak self] event in
                guard let s = self else { return }
                s._array = event.source
                s.subject.next(ObservableArrayEvent(change: event.change, source: s._array))
            }
    }
}

// MARK: DataSourceProtocol conformation

extension ObservableArrayChange {

    public var asDataSourceEventKind: DataSourceEventKind {
        switch self {
        case .reset:
            return .reload
        case .inserts(let indices):
            return .insertItems(indices.map { IndexPath(item: $0, section: 0) })
        case .deletes(let indices):
            return .deleteItems(indices.map { IndexPath(item: $0, section: 0) })
        case .updates(let indices):
            return .reloadItems(indices.map { IndexPath(item: $0, section: 0) })
        case .move(let from, let to):
            return .moveItem(IndexPath(item: from, section: 0), IndexPath(item: to, section: 0))
        case .beginBatchEditing:
            return .beginUpdates
        case .endBatchEditing:
            return .endUpdates
        }
    }
}

extension ObservableArrayEvent: DataSourceEventProtocol {

    public typealias BatchKind = BatchKindDiff

    public var kind: DataSourceEventKind {
        return change.asDataSourceEventKind
    }

    public var dataSource: [Item] {
        return source
    }
}

extension ObservableArrayPatchEvent: DataSourceEventProtocol {

    public typealias BatchKind = BatchKindPatch

    public var kind: DataSourceEventKind {
        return change.asDataSourceEventKind
    }

    public var dataSource: [Item] {
        return source
    }
}

extension ObservableArrayBase: QueryableDataSourceProtocol {

    public var numberOfSections: Int {
        return 1
    }

    public func numberOfItems(inSection section: Int) -> Int {
        return count
    }

    public func item(at index: Int) -> Item {
        return self[index]
    }
}

extension MutableObservableArray {

    public func replace(with array: [Item]) {
        lock.lock(); defer { lock.unlock() }
        self._array = array
        subject.next(ObservableArrayEvent(change: .reset, source: array))
    }
}

extension MutableObservableArray where Item: Equatable {

    public func replace(with array: [Item], performDiff: Bool) {
        if performDiff {
            lock.lock()

            let diff = self.array.extendedDiff(array)
            subject.next(ObservableArrayEvent(change: .beginBatchEditing, source: array))
            self._array = array

            for step in diff {
                switch step {
                case .insert(let index):
                    subject.next(ObservableArrayEvent(change: .inserts([index]), source: array))

                case .delete(let index):
                    subject.next(ObservableArrayEvent(change: .deletes([index]), source: array))

                case .move(let from, let to):
                    subject.next(ObservableArrayEvent(change: .move(from, to), source: array))
                }
            }

            subject.next(ObservableArrayEvent(change: .endBatchEditing, source: array))
            lock.unlock()
        } else {
            replace(with: array)
        }
    }
}

public extension SignalProtocol where Element: ObservableArrayEventProtocol {

    public typealias Item = Element.Item

    /// Map underlying ObservableArray.
    /// Complexity of mapping on each event is O(n).
    public func map<U>(_ transform: @escaping (Item) -> U) -> Signal<ObservableArrayEvent<U>> {
        return map { (event: Element) -> ObservableArrayEvent<U> in
            let mappedArray = event.source.map(transform)
            return ObservableArrayEvent<U>(change: event.change, source: mappedArray)
        }
    }

    /// Laziliy map underlying ObservableArray.
    /// Complexity of mapping on each event (change) is O(1).
    public func lazyMap<U>(_ transform: @escaping (Item) -> U) -> Signal<ObservableArrayEvent<U>> {
        return map { (event: Element) -> ObservableArrayEvent<U> in
            return ObservableArrayEvent<U>(change: event.change, source: event.source.lazy.map(transform))
        }
    }

    /// Filter underlying ObservableArrays.
    /// Complexity of filtering on each event is O(n).
    public func filter(_ isIncluded: @escaping (Item) -> Bool) -> Signal<ObservableArrayEvent<Item>> {
        var isBatching = false
        var previousIndexMap: [Int: Int] = [:]
        return map { (event: Element) -> [ObservableArrayEvent<Item>] in
            let array = event.source
            var filtered: [Item] = []
            var indexMap: [Int: Int] = [:]

            filtered.reserveCapacity(array.count)

            var iterator = 0
            for (index, element) in array.enumerated() {
                if isIncluded(element) {
                    filtered.append(element)
                    indexMap[index] = iterator
                    iterator += 1
                }
            }

            var changes: [ObservableArrayChange] = []
            switch event.change {
            case .inserts(let indices):
                let newIndices = indices.flatMap { indexMap[$0] }
                if newIndices.count > 0 {
                    changes = [.inserts(newIndices)]
                }
            case .deletes(let indices):
                let newIndices = indices.flatMap { previousIndexMap[$0] }
                if newIndices.count > 0 {
                    changes = [.deletes(newIndices)]
                }
            case .updates(let indices):
                var (updates, inserts, deletes) = ([Int](), [Int](), [Int]())
                for index in indices {
                    if let mappedIndex = indexMap[index] {
                        if let _ = previousIndexMap[index] {
                            updates.append(mappedIndex)
                        } else {
                            inserts.append(mappedIndex)
                        }
                    } else if let mappedIndex = previousIndexMap[index] {
                        deletes.append(mappedIndex)
                    }
                }
                if deletes.count > 0 { changes.append(.deletes(deletes)) }
                if updates.count > 0 { changes.append(.updates(updates)) }
                if inserts.count > 0 { changes.append(.inserts(inserts)) }
            case .move(let previousIndex, let newIndex):
                if let previous = indexMap[previousIndex], let new = indexMap[newIndex] {
                    changes = [.move(previous, new)]
                }
            case .reset:
                isBatching = false
                changes = [.reset]
            case .beginBatchEditing:
                isBatching = true
                changes = [.beginBatchEditing]
            case .endBatchEditing:
                isBatching = false
                changes = [.endBatchEditing]
            }

            if !isBatching {
                previousIndexMap = indexMap
            }

            if changes.count > 1 && !isBatching {
                changes.insert(.beginBatchEditing, at: 0)
                changes.append(.endBatchEditing)
            }

            return changes.map { ObservableArrayEvent(change: $0, source: filtered) }
            }._unwrap()
    }
}

extension SignalProtocol where Element: Collection, Element.Iterator.Element: Equatable {

    // Diff each emitted collection with the previously emitted one.
    // Returns a signal of ObservableArrayEvents that can be bound to a table or collection view.
    public func diff() -> Signal<ObservableArrayEvent<Element.Iterator.Element>> {
        return Signal { observer in
            var previous: MutableObservableArray<Element.Iterator.Element>? = nil
            return self.observe { event in
                switch event {
                case .next(let element):
                    let array = Array(element)
                    if let previous = previous {
                        let disposable = previous.skip(first: 1).observeNext { event in observer.next(event) }
                        previous.replace(with: array, performDiff: true)
                        disposable.dispose()
                    } else {
                        observer.next(ObservableArrayEvent(change: .reset, source: array))
                    }
                    previous = MutableObservableArray(array)
                case .failed(let error):
                    observer.failed(error)
                case .completed:
                    observer.completed()
                }
            }
        }
    }
}

fileprivate extension SignalProtocol where Element: Sequence {

    /// Unwrap sequence elements into signal elements.
    fileprivate func _unwrap() -> Signal<Element.Iterator.Element> {
        return Signal { observer in
            return self.observe { event in
                switch event {
                case .next(let array):
                    array.forEach { observer.next($0) }
                case .failed(let error):
                    observer.failed(error)
                case .completed:
                    observer.completed()
                }
            }
        }
    }
}

func generateDiff(from sequenceOfChanges: [ObservableArrayChange]) -> [ObservableArrayChange] {
    var diff = sequenceOfChanges.flatMap { $0.unwrap }

    for i in 0..<diff.count {
        for j in 0..<i {
            switch (diff[i], diff[j]) {

            // (deletes, *)
            case let (.deletes(l), .deletes(r)):
                guard let pivot = l.first else { break }
                guard let index = r.first else { break }
                if pivot >= index {
                    diff[i] = .deletes([pivot+1])
                }
            case let (.deletes(l), .inserts(r)):
                guard let pivot = l.first else { break }
                guard let index = r.first else { break }
                if pivot < index {
                    diff[j] = .inserts([index-1])
                } else if pivot == index {
                    diff[j] = .inserts([])
                    diff[i] = .deletes([])
                } else if pivot > index {
                    diff[i] = .deletes([pivot-1])
                }
            case let (.deletes(l), .updates(r)):
                guard let pivot = l.first else { break }
                guard let index = r.first else { break }
                if pivot == index {
                    diff[j] = .updates([])
                }
            case (let .deletes(l), let .move(from, to)):
                guard let pivot = l.first else { break }
                guard from != -1 else { break }
                var newTo = to
                if pivot == to {
                    diff[j] = .inserts([])
                    diff[i] = .deletes([from])
                    break
                } else if pivot < to {
                    newTo = to-1
                    diff[j] = .move(from, newTo)
                }
                if pivot >= from && pivot < to {
                    diff[i] = .deletes([pivot+1])
                }

            // (inserts, *)
            case (.inserts, .deletes):
                break
            case let (.inserts(l), .inserts(r)):
                guard let pivot = l.first else { break }
                guard let index = r.first else { break }
                if pivot <= index {
                    diff[j] = .inserts([index+1])
                }
            case (.inserts, .updates):
                break
            case (let .inserts(l), let .move(from, to)):
                guard let pivot = l.first else { break }
                guard from != -1 else { break }
                if pivot <= to {
                    diff[j] = .move(from, to+1)
                }

            // (updates, *)
            case let (.updates(l), .deletes(r)):
                guard let pivot = l.first else { break }
                guard let index = r.first else { break }
                if pivot >= index {
                    diff[i] = .updates([pivot+1])
                }
            case let (.updates(l), .inserts(r)):
                guard let pivot = l.first else { break }
                guard let index = r.first else { break }
                if pivot == index {
                    diff[i] = .updates([])
                }
            case let (.updates(l), .updates(r)):
                guard let pivot = l.first else { break }
                guard let index = r.first else { break }
                if pivot == index {
                    diff[i] = .updates([])
                }
            case (let .updates(l), let .move(from, to)):
                guard var pivot = l.first else { break }
                guard from != -1 else { break }
                if pivot == from {
                    // Updating item at moved indices not supported. Fallback to reset.
                    return [.reset]
                }
                if pivot >= from {
                    pivot += 1
                }
                if pivot >= to {
                    pivot -= 1
                }
                if pivot == to {
                    // Updating item at moved indices not supported. Fallback to reset.
                    return [.reset]
                }

                diff[i] = .updates([pivot])

            case (.move, _):
                // Move operations in batchUpdate must be performed first. Fallback to reset.
                return [.reset]

            default:
                break
            }
        }
    }

    return diff.filter { change -> Bool in
        switch change {
        case .deletes(let indices):
            return !indices.isEmpty
        case .inserts(let indices):
            return !indices.isEmpty
        case .updates(let indices):
            return !indices.isEmpty
        case .move(let from, let to):
            return from != -1 && to != -1
        default:
            return true
        }
    }
}

fileprivate extension ObservableArrayChange {

    fileprivate var unwrap: [ObservableArrayChange] {

        func deletionsPatch(_ indices: [Int]) -> [Int] {
            var indices = indices
            for i in 0..<indices.count {
                let pivot = indices[i]
                for j in (i+1)..<indices.count {
                    let index = indices[j]
                    if index > pivot {
                        indices[j] = index - 1
                    }
                }
            }
            return indices
        }

        func insertionsPatch(_ indices: [Int]) -> [Int] {
            var indices = indices
            for i in 0..<indices.count {
                let pivot = indices[i]
                for j in 0..<i {
                    let index = indices[j]
                    if index > pivot {
                        indices[j] = index - 1
                    }
                }
            }
            return indices
        }

        switch self {
        case .inserts(let indices):
            return insertionsPatch(indices).map { .inserts([$0]) }
        case .deletes(let indices):
            return deletionsPatch(indices).map { .deletes([$0]) }
        case .updates(let indices):
            return indices.map { .updates([$0]) }
        default:
            return [self]
        }
    }
}

extension ObservableArrayChange: Equatable {

    public static func ==(lhs: ObservableArrayChange, rhs: ObservableArrayChange) -> Bool {
        switch (lhs, rhs) {
        case (.reset, .reset):
            return true
        case (.inserts(let lhs), .inserts(let rhs)):
            return lhs == rhs
        case (.deletes(let lhs), .deletes(let rhs)):
            return lhs == rhs
        case (.updates(let lhs), .updates(let rhs)):
            return lhs == rhs
        case (.move(let lhsFrom, let lhsTo), .move(let rhsFrom, let rhsTo)):
            return lhsFrom == rhsFrom && lhsTo == rhsTo
        case (.beginBatchEditing, .beginBatchEditing):
            return true
        case (.endBatchEditing, .endBatchEditing):
            return true
        default:
            return false
        }
    }
}

public extension SignalProtocol where Element: ObservableArrayEventProtocol {

    /// Converts diff events into patch events by transforming batch updates into resets (i.e. disabling batch updates).
    /// - If you wish to keep batch updated, make your array element type conforming to Equatable protocol and use
    ///             `patchingBatch` method instead.
    public func toPatchesByResettingBatch() -> Signal<ObservableArrayPatchEvent<Item>> {

        var isBatching = false

        return Signal { observer in
            return self.observe { event in
                switch event {
                case .next(let observableArrayEvent):

                    let source = observableArrayEvent.source
                    switch observableArrayEvent.change {
                    case .beginBatchEditing:
                        isBatching = true
                    case .endBatchEditing:
                        isBatching = false
                        observer.next(.init(change: .reset, source: source))
                    default:
                        if !isBatching {
                            observer.next(.init(change: observableArrayEvent.change, source: source))
                        }
                    }

                case .failed(let error):
                    observer.failed(error)

                case .completed:
                    observer.completed()
                }
            }
        }
    }
}

public extension SignalProtocol where Element: ObservableArrayEventProtocol, Element.Item: Equatable {

    /// Converts diff events into patch events.
    public func toPatches() -> Signal<ObservableArrayPatchEvent<Item>> {

        var isBatching = false
        var originalArray: [Item] = []

        return Signal { observer in
            return self.observe { event in
                switch event {
                case .next(let observableArrayEvent):

                    let source = observableArrayEvent.source
                    switch observableArrayEvent.change {
                    case .beginBatchEditing:
                        isBatching = true
                        originalArray = source
                        observer.next(.init(change: .beginBatchEditing, source: source))
                    case .endBatchEditing:
                        isBatching = false
                        let array = observableArrayEvent.source
                        let diff = originalArray.extendedDiff(array)
                        let patch = diff.patch(from: originalArray, to: array)
                        for step in patch {
                            switch step {
                            case .insertion(let index, _):
                                observer.next(.init(change: .inserts([index]), source: source))
                            case .deletion(let index):
                                observer.next(.init(change: .deletes([index]), source: source))
                            case .move(let from, let to):
                                observer.next(.init(change: .move(from, to), source: source))
                            }
                        }
                        observer.next(.init(change: .endBatchEditing, source: source))
                    default:
                        if !isBatching {
                            observer.next(.init(change: observableArrayEvent.change, source: source))
                        }
                    }

                case .failed(let error):
                    observer.failed(error)

                case .completed:
                    observer.completed()
                }
            }
        }
    }
}
