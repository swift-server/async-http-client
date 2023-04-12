//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2023 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
@usableFromInline
struct AnyAsyncSequenceProducerDelegate: NIOAsyncSequenceProducerDelegate {
    @usableFromInline
    var delegate: NIOAsyncSequenceProducerDelegate

    @inlinable
    init<Delegate: NIOAsyncSequenceProducerDelegate>(_ delegate: Delegate) {
        self.delegate = delegate
    }

    @inlinable
    func produceMore() {
        self.delegate.produceMore()
    }

    @inlinable
    func didTerminate() {
        self.delegate.didTerminate()
    }
}
