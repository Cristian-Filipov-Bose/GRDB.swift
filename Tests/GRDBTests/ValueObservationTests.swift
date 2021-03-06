import XCTest
import Dispatch
@testable import GRDB

class ValueObservationTests: GRDBTestCase {
    func testImmediateError() throws {
        func test(_ dbWriter: DatabaseWriter) throws {
            // Create an observation
            struct TestError: Error { }
            let observation = ValueObservation.tracking { _ in throw TestError() }
            
            // Start observation
            var error: TestError?
            _ = observation.start(
                in: dbWriter,
                scheduling: .immediate,
                onError: { error = $0 as? TestError },
                onChange: { _ in })
            XCTAssertNotNil(error)
        }
        
        try test(makeDatabaseQueue())
        try test(makeDatabasePool())
    }
    
    func testErrorCompletesTheObservation() throws {
        func test(_ dbWriter: DatabaseWriter) throws {
            // We need something to change
            try dbWriter.write { try $0.execute(sql: "CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT)") }
            
            // Track reducer process
            let notificationExpectation = expectation(description: "notification")
            notificationExpectation.assertForOverFulfill = true
            notificationExpectation.expectedFulfillmentCount = 4
            notificationExpectation.isInverted = true
            
            struct TestError: Error { }
            var nextError: Error? = nil // If not null, observation throws an error
            let observation = ValueObservation.tracking {
                _ = try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM t")
                if let error = nextError {
                    throw error
                }
            }

            // Start observation
            var errorCaught = false
            let cancellable = observation.start(
                in: dbWriter,
                onError: { _ in
                    errorCaught = true
                    notificationExpectation.fulfill()
            },
                onChange: {
                    XCTAssertFalse(errorCaught)
                    nextError = TestError()
                    notificationExpectation.fulfill()
                    // Trigger another change
                    try! dbWriter.writeWithoutTransaction { db in
                        try db.execute(sql: "INSERT INTO t DEFAULT VALUES")
                    }
            })
            
            withExtendedLifetime(cancellable) {
                waitForExpectations(timeout: 1, handler: nil)
                XCTAssertTrue(errorCaught)
            }
        }
        
        try test(makeDatabaseQueue())
        try test(makeDatabasePool())
    }
    
    func testViewOptimization() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.write {
            try $0.execute(sql: """
                CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT);
                CREATE VIEW v AS SELECT * FROM t
                """)
        }
        
        // Test that view v is included in the request region
        let request = SQLRequest<Row>(sql: "SELECT name FROM v ORDER BY id")
        try dbQueue.inDatabase { db in
            let region = try request.databaseRegion(db)
            XCTAssertEqual(region.description, "t(id,name),v(id,name)")
        }
        
        // Test that view v is not included in the observed region.
        // This optimization helps observation of views that feed from a
        // single table.
        let observation = ValueObservation.tracking(request.fetchAll)
        let observer = dbQueue._addWriteOnly(
            observation: observation,
            scheduling: .immediate, // So that we can test the observedRegion
            onError: { error in XCTFail("Unexpected error: \(error)") },
            onChange: { _ in })
        XCTAssertEqual(observer.observedRegion!.description, "t(id,name)") // view is NOT tracked
    }
    
    // MARK: - Cancellation
    
    func testCancellableLifetime() throws {
        // We need something to change
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.write { try $0.execute(sql: "CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT)") }
        
        // Track reducer process
        var changesCount = 0
        let notificationExpectation = expectation(description: "notification")
        notificationExpectation.assertForOverFulfill = true
        notificationExpectation.expectedFulfillmentCount = 2
        
        // Create an observation
        let observation = ValueObservation.tracking {
            try Int.fetchOne($0, sql: "SELECT * FROM t")
        }
        
        // Start observation and deallocate cancellable after second change
        var cancellable: DatabaseCancellable?
        cancellable = observation.start(
            in: dbQueue,
            onError: { error in XCTFail("Unexpected error: \(error)") },
            onChange: { _ in
                changesCount += 1
                if changesCount == 2 {
                    cancellable = nil
                }
                notificationExpectation.fulfill()
        })
        
        // notified
        try dbQueue.write { db in
            try db.execute(sql: "INSERT INTO t DEFAULT VALUES")
        }
        
        // not notified
        try dbQueue.write { db in
            try db.execute(sql: "INSERT INTO t DEFAULT VALUES")
        }
        
        // Avoid "Variable 'cancellable' was written to, but never read" warning
        _ = cancellable
        
        waitForExpectations(timeout: 1, handler: nil)
        XCTAssertEqual(changesCount, 2)
    }
    
    func testCancellableExplicitCancellation() throws {
        // We need something to change
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.write { try $0.execute(sql: "CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT)") }
        
        // Track reducer process
        var changesCount = 0
        let notificationExpectation = expectation(description: "notification")
        notificationExpectation.assertForOverFulfill = true
        notificationExpectation.expectedFulfillmentCount = 2
        
        // Create an observation
        let observation = ValueObservation.tracking {
            try Int.fetchOne($0, sql: "SELECT * FROM t")
        }
        
        // Start observation and cancel cancellable after second change
        var cancellable: DatabaseCancellable!
        cancellable = observation.start(
            in: dbQueue,
            onError: { error in XCTFail("Unexpected error: \(error)") },
            onChange: { _ in
                changesCount += 1
                if changesCount == 2 {
                    cancellable.cancel()
                }
                notificationExpectation.fulfill()
        })
        
        try withExtendedLifetime(cancellable) {
            // notified
            try dbQueue.write { db in
                try db.execute(sql: "INSERT INTO t DEFAULT VALUES")
            }
            
            // not notified
            try dbQueue.write { db in
                try db.execute(sql: "INSERT INTO t DEFAULT VALUES")
            }
            
            waitForExpectations(timeout: 1, handler: nil)
            XCTAssertEqual(changesCount, 2)
        }
    }
    
    func testCancellableInvalidation1() throws {
        // Test that observation stops when cancellable is deallocated
        func test(_ dbWriter: DatabaseWriter) throws {
            try dbWriter.write { try $0.execute(sql: "CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT)") }

            let notificationExpectation = expectation(description: "notification")
            notificationExpectation.isInverted = true
            notificationExpectation.expectedFulfillmentCount = 2

            do {
                var cancellable: DatabaseCancellable? = nil
                _ = cancellable // Avoid "Variable 'cancellable' was written to, but never read" warning
                var shouldStopObservation = false
                let observation = ValueObservation(makeReducer: {
                    AnyValueReducer<Void, Void>(
                        fetch: { _ in
                            if shouldStopObservation {
                                cancellable = nil /* deallocation */
                            }
                            shouldStopObservation = true
                    },
                        value: { _ in () })
                })
                cancellable = observation.start(
                    in: dbWriter,
                    scheduling: .immediate,
                    onError: { error in XCTFail("Unexpected error: \(error)") },
                    onChange: { _ in
                        notificationExpectation.fulfill()
                })
            }

            try dbWriter.write { db in
                try db.execute(sql: "INSERT INTO t DEFAULT VALUES")
            }
            waitForExpectations(timeout: 1, handler: nil)
        }

        try test(makeDatabaseQueue())
        try test(makeDatabasePool())
    }
    
    func tesCancellableInvalidation2() throws {
        // Test that observation stops when cancellable is deallocated
        func test(_ dbWriter: DatabaseWriter) throws {
            try dbWriter.write { try $0.execute(sql: "CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT)") }
            
            let notificationExpectation = expectation(description: "notification")
            notificationExpectation.isInverted = true
            notificationExpectation.expectedFulfillmentCount = 2
            
            do {
                var cancellable: DatabaseCancellable? = nil
                _ = cancellable // Avoid "Variable 'cancellable' was written to, but never read" warning
                var shouldStopObservation = false
                let observation = ValueObservation(makeReducer: {
                    AnyValueReducer<Void, Void>(
                        fetch: { _ in },
                        value: { _ in
                            if shouldStopObservation {
                                cancellable = nil /* deallocation right before notification */
                            }
                            shouldStopObservation = true
                            return ()
                    })
                })
                cancellable = observation.start(
                    in: dbWriter,
                    scheduling: .immediate,
                    onError: { error in XCTFail("Unexpected error: \(error)") },
                    onChange: { _ in
                        notificationExpectation.fulfill()
                })
            }
            
            try dbWriter.write { db in
                try db.execute(sql: "INSERT INTO t DEFAULT VALUES")
            }
            waitForExpectations(timeout: 1, handler: nil)
        }
        
        try test(makeDatabaseQueue())
        try test(makeDatabasePool())
    }
}
