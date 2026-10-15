import AppKit
import Combine
import QuickChatCore
import XCTest
@testable import QuickChat

final class DraftTests: XCTestCase {
    @MainActor func testNewChatMovesDraftAndKeepsHistoryAndScreenshotOwnership() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("QuickChat-DraftTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let history = HistoryStore(root: root)
        let store = ChatStore(demo: true, history: history)
        let pixels = Data([1, 2, 3])
        let attachment = try await history.storeImage(pixels, width: 1, height: 1)
        var original = Conversation(model: "chosen-model")
        original.messages = [Message(role: "user", text: "Earlier question"), Message(role: "assistant", text: "Earlier answer")]
        original.draft = "Rewrite this:\nOlá 👋"
        original.draftAttachments = [attachment]
        original.searchEnabled = false
        var other = Conversation(); other.draft = "Another chat's draft"
        store.chats = [original, other]; store.select(original.id)

        store.newChat()

        let fresh = try XCTUnwrap(store.current)
        XCTAssertNotEqual(fresh.id, original.id)
        XCTAssertTrue(fresh.messages.isEmpty)
        XCTAssertEqual(fresh.draft, original.draft)
        XCTAssertEqual(fresh.draftAttachments, [attachment])
        XCTAssertEqual(fresh.model, original.model)
        XCTAssertFalse(fresh.searchEnabled)
        XCTAssertEqual(store.chats.first(where: { $0.id == other.id })?.draft, other.draft)
        await store.flush()
        XCTAssertNil(store.error)
        let saved = try await history.load()
        let previous = try XCTUnwrap(saved.first(where: { $0.id == original.id }))
        XCTAssertEqual(previous.messages.map(\.text), original.messages.map(\.text))
        XCTAssertTrue(previous.draft.isEmpty)
        XCTAssertTrue(previous.draftAttachments.isEmpty)
        XCTAssertEqual(saved.first(where: { $0.id == fresh.id })?.draft, original.draft)
        XCTAssertEqual(saved.first(where: { $0.id == fresh.id })?.draftAttachments, [attachment])
        try await history.delete(previous)
        XCTAssertEqual(try Data(contentsOf: history.imageURL(attachment)), pixels,
            "Deleting the old conversation must not delete screenshots carried into the new draft.")
    }

    @MainActor func testScreenshotStillProcessingFollowsDraftAcrossNewChats() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("QuickChat-DraftTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let history = HistoryStore(root: root)
        let store = ChatStore(demo: true, history: history)
        store.newChat(); store.setDraft("About this screenshot")
        let originalID = try XCTUnwrap(store.selectedID)
        let pixels = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let image = NSImage(size: NSSize(width: 2, height: 2)); image.addRepresentation(pixels)
        // No await before the new chats: conversion cannot finish on the main actor yet.
        store.attach(image)
        store.newChat(); store.newChat()
        let destination = try XCTUnwrap(store.selectedID)
        store.select(originalID)
        let attached = expectation(description: "Screenshot reaches the draft's new conversation")
        let observation = store.$chats.first { chats in
            chats.contains { $0.id == destination && $0.draftAttachments.count == 1 }
        }.sink { _ in attached.fulfill() }
        await fulfillment(of: [attached], timeout: 5)
        observation.cancel()
        XCTAssertNil(store.error)
        XCTAssertEqual(store.selectedID, originalID)
        XCTAssertTrue(store.current?.draftAttachments.isEmpty == true)
        let moved = try XCTUnwrap(store.chats.first(where: { $0.id == destination }))
        XCTAssertEqual(moved.draft, "About this screenshot")
        let attachment = try XCTUnwrap(moved.draftAttachments.first)
        XCTAssertEqual(attachment.width, 2)
        XCTAssertNotNil(NSImage(contentsOf: history.imageURL(attachment)))
        await store.flush()
    }
}
