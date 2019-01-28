#!/usr/bin/env python3
# -------------------------------------------------------------------------------------------------
# <copyright file="test_backtest_data.py" company="Invariance Pte">
#  Copyright (C) 2018-2019 Invariance Pte. All rights reserved.
#  The use of this source code is governed by the license as found in the LICENSE.md file.
#  http://www.invariance.com
# </copyright>
# -------------------------------------------------------------------------------------------------

import pandas as pd
import unittest

from decimal import Decimal
from datetime import datetime, timezone, timedelta

from inv_trader.common.clock import TestClock
from inv_trader.common.guid import TestGuidFactory
from inv_trader.common.logger import Logger
from inv_trader.model.enums import Venue, OrderSide
from inv_trader.model.identifiers import Label, OrderId, PositionId
from inv_trader.model.objects import Symbol, Price
from inv_trader.model.events import OrderRejected, OrderWorking, OrderModified, OrderFilled
from inv_trader.backtest.execution import BacktestExecClient
from test_kit.strategies import TestStrategy1
from test_kit.data import TestDataProvider
from test_kit.stubs import TestStubs

UNIX_EPOCH = TestStubs.unix_epoch()
USDJPY_FXCM = Symbol('USDJPY', Venue.FXCM)


class BacktestExecClientTests(unittest.TestCase):

    def setUp(self):
        # Fixture Setup
        self.usdjpy = TestStubs.instrument_usdjpy()
        self.bid_data_1min = TestDataProvider.usdjpy_1min_bid()[:2000]
        self.ask_data_1min = TestDataProvider.usdjpy_1min_ask()[:2000]

        self.instruments = [self.usdjpy]
        self.data_ticks = {self.usdjpy.symbol: pd.DataFrame()}
        self.data_bars_bid = {self.usdjpy.symbol: self.bid_data_1min}
        self.data_bars_ask = {self.usdjpy.symbol: self.ask_data_1min}

        self.strategies = [TestStrategy1(TestStubs.bartype_usdjpy_1min_bid())]

        self.client = BacktestExecClient(instruments=self.instruments,
                                         data_ticks=self.data_ticks,
                                         data_bars_bid=self.data_bars_bid,
                                         data_bars_ask=self.data_bars_ask,
                                         starting_capital=1000000,
                                         slippage_ticks=1,
                                         clock=TestClock(),
                                         guid_factory=TestGuidFactory(),
                                         logger=Logger())

    def test_can_initialize_client_with_data(self):
        # Arrange
        # Act
        # Assert
        self.assertEqual(all(self.bid_data_1min.index), all(self.client.data_minute_index))
        self.assertEqual(Decimal(1000000), self.client.account.cash_balance)
        self.assertEqual(Decimal(1000000), self.client.account.free_equity)
        self.assertEqual(Decimal('0.001'), self.client.slippage_index[self.usdjpy.symbol])

    def test_can_set_initial_iteration(self):
        # Arrange
        start = datetime(2013, 1, 2, 0, 0, 0, 0, tzinfo=timezone.utc)

        # Act
        self.client.set_initial_iteration(start, timedelta(minutes=1))

        # Assert
        self.assertEqual(1440, self.client.iteration)
        self.assertEqual(start, self.client.time_now())

    def test_can_send_collateral_inquiry(self):
        # Arrange
        # Act
        self.client.collateral_inquiry()

        # Assert
        self.assertEqual(2, self.client.account.event_count)

    def test_can_submit_market_order(self):
        # Arrange
        strategy = TestStrategy1(bar_type=TestStubs.bartype_usdjpy_1min_bid())
        self.client.register_strategy(strategy)
        strategy.start()

        order = strategy.order_factory.market(
            USDJPY_FXCM,
            OrderId('123456'),
            Label('S1_E'),
            OrderSide.BUY,
            100000)

        # Act
        strategy.submit_order(order, PositionId(str(order.id)))

        # Assert
        self.assertEqual(4, strategy.object_storer.count)
        self.assertTrue(isinstance(strategy.object_storer.get_store()[3], OrderFilled))
        self.assertEqual(Price('86.711'), order.average_price)

    def test_can_submit_limit_order(self):
        # Arrange
        strategy = TestStrategy1(bar_type=TestStubs.bartype_usdjpy_1min_bid())
        self.client.register_strategy(strategy)
        strategy.start()

        order = strategy.order_factory.limit(
            USDJPY_FXCM,
            OrderId('123456'),
            Label('S1_E'),
            OrderSide.BUY,
            100000,
            Price('80.000'))

        # Act
        strategy.submit_order(order, PositionId(str(order.id)))

        # Assert
        print(strategy.object_storer.get_store())
        self.assertEqual(4, strategy.object_storer.count)
        self.assertTrue(isinstance(strategy.object_storer.get_store()[3], OrderWorking))
        self.assertEqual(Price('80.000'), order.price)

    def test_can_modify_stop_order(self):
        # Arrange
        strategy = TestStrategy1(bar_type=TestStubs.bartype_usdjpy_1min_bid())
        self.client.register_strategy(strategy)
        strategy.start()

        order = strategy.order_factory.stop_market(
            USDJPY_FXCM,
            OrderId('123456'),
            Label('S1_E'),
            OrderSide.BUY,
            100000,
            Price('86.711'))

        strategy.submit_order(order, PositionId(str(order.id)))

        # Act
        strategy.modify_order(order, Price('86.712'))

        # Assert
        self.assertEqual(Price('86.712'), order.price)
        self.assertEqual(5, strategy.object_storer.count)
        self.assertTrue(isinstance(strategy.object_storer.get_store()[4], OrderModified))

    def test_order_with_invalid_price_gets_rejected(self):
        # Arrange
        strategy = TestStrategy1(bar_type=TestStubs.bartype_usdjpy_1min_bid())
        self.client.register_strategy(strategy)
        strategy.start()

        order = strategy.order_factory.stop_market(
            USDJPY_FXCM,
            OrderId('123456'),
            Label('S1_E'),
            OrderSide.BUY,
            100000,
            Price('80.000'))

        # Act
        strategy.submit_order(order, PositionId(str(order.id)))

        # Assert
        self.assertEqual(4, strategy.object_storer.count)
        self.assertTrue(isinstance(strategy.object_storer.get_store()[3], OrderRejected))