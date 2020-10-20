//
//  Created by Dimitrios Chatzieleftheriou on 26/05/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import XCTest

@testable import AudioStreaming

class NetworkingClientTests: XCTestCase {

    func testInitialiseCorrectly() throws {
        let networking = NetworkingClient()
        
        XCTAssertNotNil(networking.session.delegate)
        XCTAssert(networking.delegate === networking.session.delegate)
    }

    func testInitialiseCorrectlyWithCustomArguments() {
        let configuration = URLSessionConfiguration.default
        let delegate = NetworkSessionDelegate()
        let queue = DispatchQueue(label: "temp.queue")
        
        let networking = NetworkingClient(configuration: configuration,
                                          delegate: delegate,
                                          networkQueue: queue)
        
        XCTAssertNotNil(networking.session)
        XCTAssertTrue(networking.delegate === networking.session.delegate)
        XCTAssertTrue(networking.networkQueue == queue)
    }
        
    let networking = NetworkingClient()
    func testShouldStartRequestImmediatelly() {
        
        let url = URL(string: "https://httpbin.org/get")!
        let request = URLRequest(url: url)
        
        let expectation = self.expectation(description: "\(url)")
        
        var responseCompletion: NetworkDataStream.Completion?
        var receivedData: Data?
        
        networking.stream(request: request)
            .responseStream { event in
                switch event {
                case .stream(let result):
                    switch result {
                    case .success(let value):
                        receivedData = value.data
                    case .failure: break
                    }
                case .complete(let completion):
                    responseCompletion = completion
                    expectation.fulfill()
                case .response:
                    break
                }
            }
            .resume()
        
        waitForExpectations(timeout: 10, handler: nil)
        
        XCTAssertEqual(responseCompletion?.response?.statusCode, 200)
        XCTAssertNotNil(responseCompletion)
        XCTAssertNotNil(receivedData)
    }
    
    func testThatStreamCanBeCalledAndCompleteAtAGivenThread() {
        let networking = NetworkingClient()
        
        let url = URL(string: "https://httpbin.org/get")!
        let request = URLRequest(url: url)
        
        let expectation = self.expectation(description: "\(url)")
        
        var responseCompletion: NetworkDataStream.Completion?
        var receivedData: Data?
                
        networking.stream(request: request)
            .responseStream { event in
                switch event {
                case .stream(let result):
                    XCTAssertFalse(Thread.current.isMainThread)
                    switch result {
                    case .success(let value):
                        receivedData = value.data
                    case .failure: break
                    }
                case .complete(let completion):
                    XCTAssertFalse(Thread.current.isMainThread)
                    responseCompletion = completion
                    expectation.fulfill()
                case .response:
                        XCTAssertFalse(Thread.current.isMainThread)
                }
            }
            .resume()
        
        waitForExpectations(timeout: 10, handler: nil)
        
        XCTAssertEqual(responseCompletion?.response?.statusCode, 200)
        XCTAssertNotNil(responseCompletion)
        XCTAssertNotNil(receivedData)
    }
    
}
