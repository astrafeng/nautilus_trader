# -------------------------------------------------------------------------------------------------
#  Copyright (C) 2015-2021 Nautech Systems Pty Ltd. All rights reserved.
#  https://nautechsystems.io
#
#  Licensed under the GNU Lesser General Public License Version 3.0 (the "License");
#  You may not use this file except in compliance with the License.
#  You may obtain a copy of the License at https://www.gnu.org/licenses/lgpl-3.0.en.html
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
# -------------------------------------------------------------------------------------------------

import asyncio

import pytest

from nautilus_trader.adapters.ccxt.factories import CCXTDataClientFactory
from nautilus_trader.adapters.ccxt.factories import CCXTExecutionClientFactory
from nautilus_trader.common.enums import ComponentState
from nautilus_trader.live.node import TradingNode


class TestTradingNodeConfiguration:
    def test_config_with_inmemory_execution_database(self):
        # Arrange
        config = {
            "trader": {
                "name": "tester",
                "id_tag": "000",
            },
            "logging": {
                "log_level_console": "INF",
            },
            "database": {
                "type": "in-memory",
            },
            "strategy": {
                "load_state": True,
                "save_state": True,
            },
            "data_clients": {
                "binance": {
                    "api_key": "BINANCE_API_KEY",  # value is the environment variable name
                    "api_secret": "BINANCE_API_SECRET",  # value is the environment variable name
                },
            },
            "exec_clients": {
                "binance": {
                    "api_key": "BINANCE_API_KEY",  # value is the environment variable name
                    "api_secret": "BINANCE_API_SECRET",  # value is the environment variable name
                },
            },
        }

        # Act
        node = TradingNode(config=config)

        # Assert
        assert node is not None

    def test_config_with_redis_execution_database(self):
        # Arrange
        config = {
            "trader": {
                "name": "tester",
                "id_tag": "000",
            },
            "logging": {
                "log_level_console": "INF",
            },
            "database": {
                "type": "redis",
                "host": "localhost",
                "port": 6379,
            },
            "strategy": {
                "load_state": True,
                "save_state": True,
            },
            "data_clients": {
                "binance": {
                    "api_key": "BINANCE_API_KEY",  # value is the environment variable name
                    "api_secret": "BINANCE_API_SECRET",  # value is the environment variable name
                },
            },
            "exec_clients": {
                "binance": {
                    "api_key": "BINANCE_API_KEY",  # value is the environment variable name
                    "api_secret": "BINANCE_API_SECRET",  # value is the environment variable name
                },
            },
        }

        # Act
        node = TradingNode(config=config)

        # Assert
        assert node is not None


class TestTradingNodeOperation:
    def setup(self):
        # Fixture Setup
        self.config = {
            "trader": {
                "name": "TESTER",
                "id_tag": "000",
            },
            "logging": {
                "log_level_console": "INF",
            },
            "database": {
                "type": "in-memory",
            },
            "strategy": {
                "load_state": True,
                "save_state": True,
            },
            "data_clients": {},
            "exec_clients": {},
        }

        self.node = TradingNode(config=self.config)

    def test_get_event_loop_returns_a_loop(self):
        # Arrange
        node = TradingNode(config=self.config)

        # Act
        loop = node.get_event_loop()

        # Assert
        assert isinstance(loop, asyncio.AbstractEventLoop)

    def test_add_data_client_factory(self, capsys):
        # Arrange
        self.config["data_clients"]["CCXT-BITMEX"] = {}

        node = TradingNode(config=self.config)

        # Act
        node.add_data_client_factory("CCXT", CCXTDataClientFactory)
        node.build()

        # Assert
        log = "".join(capsys.readouterr())
        assert "TESTER-000.CCXTDataClient-BITMEX: INITIALIZED." in log

    def test_add_exec_client_factory(self, capsys):
        # Arrange
        self.config["exec_clients"]["CCXT-BITMEX"] = {}

        node = TradingNode(config=self.config)

        # Act
        node.add_exec_client_factory("CCXT", CCXTExecutionClientFactory)
        node.build()

        # Assert
        log = "".join(capsys.readouterr())
        assert "TESTER-000.CCXTExecClient-BITMEX: INITIALIZED." in log

    @pytest.mark.asyncio
    async def test_register_log_sink(self):
        # Arrange
        sink = []

        # Act
        self.node.add_log_sink(sink.append)
        self.node.build()

        self.node.start()
        await asyncio.sleep(1)

        # Assert: Log record received
        assert sink[-1]["trader_id"] == self.node.trader_id.value
        assert sink[-1]["host_id"] == self.node.host_id
        assert sink[-1]["instance_id"] == self.node.instance_id.value

    @pytest.mark.asyncio
    async def test_start(self):
        # Arrange
        self.node.build()

        # Act
        self.node.start()
        await asyncio.sleep(2)

        # Assert
        assert self.node.trader.state == ComponentState.RUNNING

    @pytest.mark.asyncio
    async def test_stop(self):
        # Arrange
        self.node.build()
        self.node.start()
        await asyncio.sleep(2)  # Allow node to start

        # Act
        self.node.stop()
        await asyncio.sleep(3)  # Allow node to stop

        # Assert
        assert self.node.trader.state == ComponentState.STOPPED

    @pytest.mark.skip(reason="refactor TradingNode coroutines")
    @pytest.mark.asyncio
    async def test_dispose(self):
        # Arrange
        self.node.build()
        self.node.start()
        await asyncio.sleep(2)  # Allow node to start

        self.node.stop()
        await asyncio.sleep(2)  # Allow node to stop

        # Act
        self.node.dispose()
        await asyncio.sleep(1)  # Allow node to dispose

        # Assert
        assert self.node.trader.state == ComponentState.DISPOSED
