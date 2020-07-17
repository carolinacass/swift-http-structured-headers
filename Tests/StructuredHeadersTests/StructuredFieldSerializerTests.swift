//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
import Foundation
import StructuredHeaders
import XCTest

final class StructuredFieldSerializerTests: XCTestCase {
    enum TestResult<BaseData: RandomAccessCollection> where BaseData.Element == UInt8, BaseData.SubSequence == BaseData, BaseData: Hashable {
        case dictionary(OrderedMap<String, ItemOrInnerList<BaseData>>)
        case list([ItemOrInnerList<BaseData>])
        case item(Item<BaseData>)
    }

    private func _runSerializationTest(_ fixture: StructuredHeaderTestFixture) {
        guard let expected = fixture.expected else {
            fatalError("No structure to serialize")
        }

        do {
            let toSerialize: TestResult<ArraySlice<UInt8>>
            do {
                toSerialize = try TestResult<ArraySlice<UInt8>>(expected)
            } catch let error as StructuredHeaderError where error == .invalidIntegerOrDecimal {
                // We expect this error, it's fine
                return
            }

            var serializer = StructuredFieldSerializer()

            let result: [UInt8]
            switch toSerialize {
            case .dictionary(let dictionary):
                result = try serializer.writeDictionaryHeader(dictionary)
            case .list(let list):
                result = try serializer.writeListHeader(list)
            case .item(let item):
                result = try serializer.writeItemHeader(item)
            }

            if fixture.mustFail == true || fixture.canFail == true {
                XCTFail("\(fixture.name): Fixture did not throw when serializing.")
            } else if let canonical = fixture.canonical {
                let expectedCanonicalForm = canonical.joined(separator: ", ")
                XCTAssertEqual(Array(expectedCanonicalForm.utf8), result,
                               "\(fixture.name): Bad serialization, expected \(expectedCanonicalForm), got \(String(decoding: result, as: UTF8.self))")
            }
        } catch {
            XCTAssert(fixture.mustFail == true || fixture.canFail == true,
                      "\(fixture.name): Unexpected failure, threw error \(error)")
        }
    }

    private func _runRoundTripTest(_ fixture: StructuredHeaderTestFixture) {
        guard let raw = fixture.raw else {
            fatalError("Cannot run round-trip test without raw header.")
        }

        let joinedHeaders = Array(raw.joined(separator: ", ").utf8)

        do {
            var parser = StructuredFieldParser(joinedHeaders)

            let testResult: TestResult<ArraySlice<UInt8>>
            switch fixture.headerType {
            case "dictionary":
                testResult = try .dictionary(parser.parseDictionaryField())
            case "list":
                testResult = try .list(parser.parseListField())
            case "item":
                testResult = try .item(parser.parseItemField())
            default:
                XCTFail("\(fixture.name): Unexpected header type \(fixture.headerType)")
                return
            }

            var serializer = StructuredFieldSerializer()
            let serialized: [UInt8]

            let canonicalJoinedHeaders: [UInt8]
            if let canonical = fixture.canonical {
                canonicalJoinedHeaders = Array(canonical.joined(separator: ", ").utf8)
            } else {
                canonicalJoinedHeaders = joinedHeaders
            }

            switch testResult {
            case .dictionary(let result):
                serialized = try serializer.writeDictionaryHeader(result)
            case .list(let list):
                serialized = try serializer.writeListHeader(list)
            case .item(let item):
                serialized = try serializer.writeItemHeader(item)
            }

            XCTAssertEqual(canonicalJoinedHeaders, serialized, "\(fixture.name): Header serialization mismatch: expected \(String(decoding: canonicalJoinedHeaders, as: UTF8.self)), got \(String(decoding: serialized, as: UTF8.self))")
        } catch {
            XCTFail("\(fixture.name): Fixture threw unexpected error \(error)")
        }
    }

    func testCanPassAllParsingFixtures() throws {
        // This is a bulk-test: we run across all the fixtures in the fixtures directory to confirm we can handle all of them.
        for fixture in FixturesLoader.parsingFixtures {
            if fixture.mustFail != true, fixture.canFail != true {
                self._runRoundTripTest(fixture)
            }
        }
    }

    func testCanPassAllSerializationFixtures() throws {
        // This is a bulk-test: we run across all the fixtures in the fixtures directory to confirm we can handle all of them.
        for fixture in FixturesLoader.serializingFixtures {
            self._runSerializationTest(fixture)
        }
    }
}

extension StructuredFieldSerializerTests.TestResult where BaseData == ArraySlice<UInt8> {
    init(_ schema: JSONSchema) throws {
        switch schema {
        case .dictionary(let dictionary):
            // Top level JSON objects are encoding dictionaries.
            var dict = OrderedMap<String, ItemOrInnerList<BaseData>>()

            for (name, value) in dictionary {
                dict[name] = try ItemOrInnerList(value)
            }

            self = .dictionary(dict)

        case .array(let jsonArray):
            // Top level JSON arrays may be either list headers or item headers. To know, we have
            // to investigate a bit. An item will have only two entries, and neither will be an array.
            if jsonArray.count == 2, let first = jsonArray.first, let last = jsonArray.last, !first.isArray, !last.isArray {
                // This is an item!
                self = .item(try Item(schema))
            } else {
                self = .list(try jsonArray.map { try ItemOrInnerList($0) })
            }
        case .bool, .double, .integer, .string:
            fatalError("Invalid top-level JSON object \(schema)")
        }
    }
}

extension ItemOrInnerList where BaseData == ArraySlice<UInt8> {
    init(_ schema: JSONSchema) throws {
        // We need to detect the difference between an item or inner list. Both will be JSON arrays, but
        // in the case of inner list the first element will be an array, while for an item it will not.
        guard case .array(let arrayElements) = schema, arrayElements.count == 2, let first = arrayElements.first else {
            fatalError("Invalid item or inner list: \(schema)")
        }

        if case .array = first {
            self = .innerList(try InnerList(schema))
        } else {
            self = .item(try Item(schema))
        }
    }
}

extension Item where BaseData == ArraySlice<UInt8> {
    init(_ schema: JSONSchema) throws {
        guard case .array(let arrayElements) = schema, arrayElements.count == 2, let first = arrayElements.first, let last = arrayElements.last else {
            fatalError("Invalid item: \(schema)")
        }

        self.init(bareItem: try BareItem(first), parameters: try OrderedMap(parameters: last))
    }
}

extension BareItem where BaseData == ArraySlice<UInt8> {
    init(_ schema: JSONSchema) throws {
        switch schema {
        case .integer(let int):
            self = .integer(int)
        case .double(let double):
            self = try .decimal(.init(double))
        case .string(let string):
            self = .string(string)
        case .dictionary(let typeObject):
            switch (typeObject["__type"], typeObject["value"]) {
            case (.some(.string("token")), .some(.string(let value))):
                self = .token(value)

            case (.some(.string("binary")), .some(.string(let value))):
                let expectedBase64Bytes = Data(base32Encoded: Data(value.utf8)).base64EncodedData()
                self = .undecodedByteSequence(ArraySlice(expectedBase64Bytes))

            default:
                preconditionFailure("Unexpected type object \(typeObject)")
            }
        case .bool(let bool):
            self = .bool(bool)
        case .array:
            preconditionFailure("Base item cannot be JSON array")
        }
    }
}

extension InnerList where BaseData == ArraySlice<UInt8> {
    init(_ schema: JSONSchema) throws {
        guard case .array(let arrayElements) = schema, arrayElements.count == 2, let first = arrayElements.first, let last = arrayElements.last else {
            fatalError("Invalid item: \(schema)")
        }

        self.init(bareInnerList: try BareInnerList(first), parameters: try OrderedMap(parameters: last))
    }
}

extension BareInnerList where BaseData == ArraySlice<UInt8> {
    init(_ schema: JSONSchema) throws {
        guard case .array(let items) = schema else {
            fatalError("Unexpected bare inner list object \(schema)")
        }

        self.init()

        for element in items {
            self.append(try Item(element))
        }
    }
}

extension OrderedMap where Key == String, Value == BareItem<ArraySlice<UInt8>> {
    init(parameters: JSONSchema) throws {
        guard case .dictionary(let jsonDict) = parameters else {
            fatalError("Invalid format for parameters: \(parameters)")
        }

        self.init()

        for (name, value) in jsonDict {
            self[name] = try BareItem(value)
        }
    }
}
