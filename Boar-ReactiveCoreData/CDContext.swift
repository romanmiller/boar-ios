//
//  CoreDataContext.swift
//  Boar-ReactiveCoreData
//
//  Created by Peter Ovchinnikov on 1/19/18.
//  Copyright © 2018 Peter Ovchinnikov. All rights reserved.
//

import Foundation
import CoreData
import BrightFutures
import Boar_Reactive

final public class CDContext {
    
    private var managedObjectModel : NSManagedObjectModel
    private var coordinator : NSPersistentStoreCoordinator
    
    
    private let coordinatorQueue = DispatchQueue(label: "com.boar.core-data-coordinator-\(UUID().uuidString)", attributes: DispatchQueue.Attributes())
    private let backgroundQueue = DispatchQueue(label: "com.boar.core-data-background-\(UUID().uuidString)", attributes: DispatchQueue.Attributes())
    
    
    private var сoordinatorContext : NSManagedObjectContext!
    private var backgroundContext : NSManagedObjectContext!
    private var store: NSPersistentStore
    public init(_ modelURL:URL, sqliteURL:URL) throws {
        assert(Thread.isMainThread, "init should be called from main thread only")
        
        
        managedObjectModel = NSManagedObjectModel(contentsOf: modelURL)!
        coordinator        = NSPersistentStoreCoordinator(managedObjectModel: managedObjectModel)
        
        store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: sqliteURL, options: [NSMigratePersistentStoresAutomaticallyOption: true, NSInferMappingModelAutomaticallyOption: true])
        
        coordinatorQueue.sync {
            self.сoordinatorContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            self.сoordinatorContext.persistentStoreCoordinator = self.coordinator
        }
        
        backgroundQueue.sync {
            self.backgroundContext = self.сoordinatorContext.create(merge: true)
        }
    }
    
    public func remove(){
        if let url = store.url {
            try? coordinator.persistentStores.forEach(coordinator.remove)
            try? FileManager.default.removeItem(at: url)
        }
    }
    
    public typealias Operation = (NSManagedObjectContext) throws -> Void
    public struct ChangedContext {
        public let inserted: Set<NSManagedObject>
        public let updated: Set<NSManagedObject>
        public let deleted: Set<NSManagedObject>
    }
    @discardableResult
    public func perform(operations: @escaping () -> [Operation] ) -> Future<CDContext.ChangedContext, NSError>{
        return сoordinatorContext.transaction{context -> CDContext.ChangedContext in
            try operations().forEach{ try $0(context) }
            return ChangedContext(inserted: context.insertedObjects,
                                  updated: context.updatedObjects,
                                  deleted: context.deletedObjects)
        }
    }

    public func find<T:NSManagedObject>(_ type: T.Type, pred: NSPredicate, order: [(String,Bool)], count: Int?)->Future<[T], NSError> {
        return backgroundContext.async{ context in
            return try context.find(type, pred: pred, order: order, count: count)
        }
    }
}
//Senseless stuff :)
public extension CDContext {
    public struct ChangedContextTransact {
        public let inserted: Set<NSManagedObject>
        public let updated: Set<NSManagedObject>
        public let deleted: Set<NSManagedObject>
        fileprivate let transact: NSManagedObjectContext
        public func confirm()-> Future<Void, NSError>{
            return transact.async{ ctx in
                try ctx.save()
            }
        }
        public func rollback()->Future<Void, NSError>{
            return transact.async{ ctx in
                print (ctx.updatedObjects.count)
                ctx.rollback()
                try ctx.save()
                try ctx.parent?.save()
            }
        }
    }


    //    @discardableResult
    public func performConfirm(operations: @escaping () -> [Operation]) -> Future<CDContext.ChangedContextTransact, NSError>{
        return сoordinatorContext.transaction{ context in
            let transact = context.create(merge: false)
            let oper = operations()
            try transact.sync { contex in
                try oper.forEach{ try $0(context) }
            }
            try oper.forEach{ try $0(context) }
            return ChangedContextTransact(inserted: context.insertedObjects,
                                          updated: context.updatedObjects,
                                          deleted: context.deletedObjects,
                                          transact: transact)
        }
    }
}


public extension CDContext {
    func fetch<T:NSManagedObject>(_ type: T.Type, initial: NSPredicate, order: [(String,Bool)]) -> CDFetchedObservable<T> {
        return CDFetchedObservable(parent: сoordinatorContext,initial: initial, order: order)
    }
}


internal extension NSManagedObject {
    class func entityName()->String {
        if #available(iOS 10.0, *) {
            return self.entity().name!
        } else {
            let entity = self.description().components(separatedBy: ".").last
            return entity!
        }
    }
}

internal extension NSManagedObjectContext {
    convenience init(parent: NSManagedObjectContext, merge: Bool) {
        self.init(concurrencyType: .privateQueueConcurrencyType)
        self.parent = parent
        self.automaticallyMergesChangesFromParent = true
    }
    func create(merge: Bool) -> NSManagedObjectContext {
        return NSManagedObjectContext(parent: self, merge: merge)
    }
    
    func find<T:NSManagedObject>(_ type: T.Type, pred: NSPredicate, order: [(String,Bool)], count: Int?) throws  -> [T] {
        
        let request = NSFetchRequest<T>(entityName: T.entityName())
        request.predicate = pred
        
        var sortDesriptors = [NSSortDescriptor]()
        for (sortTerm, ascending) in order {
            sortDesriptors.append(NSSortDescriptor(key: sortTerm, ascending: ascending))
        }
        request.sortDescriptors = sortDesriptors
        if let count = count {
            request.fetchLimit = count
        }
        
        let objects = try! fetch(request)
        return objects
    }
}

