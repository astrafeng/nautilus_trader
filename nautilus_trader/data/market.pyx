# -------------------------------------------------------------------------------------------------
# <copyright file="market.pyx" company="Nautech Systems Pty Ltd">
#  Copyright (C) 2015-2020 Nautech Systems Pty Ltd. All rights reserved.
#  The use of this source code is governed by the license as found in the LICENSE.md file.
#  https://nautechsystems.io
# </copyright>
# -------------------------------------------------------------------------------------------------

import inspect
import numpy as np
import pandas as pd

from cpython.datetime cimport datetime
from typing import Callable, List
from pandas.core.frame import DataFrame

from nautilus_trader.core.correctness cimport Condition
from nautilus_trader.core.functions cimport with_utc_index
from nautilus_trader.model.c_enums.quote_type cimport QuoteType, quote_type_to_string
from nautilus_trader.model.c_enums.bar_structure cimport BarStructure
from nautilus_trader.model.identifiers cimport Symbol
from nautilus_trader.model.objects cimport Price, Tick, Bar, DataBar, BarSpecification


cdef class TickDataWrangler:
    """
    Provides a means of building lists of ticks from the given Pandas DataFrames
    of bid and ask data. Provided data can either be tick data or bar data.
    """
    def __init__(self,
                 Symbol symbol,
                 int precision,
                 tick_data: DataFrame=None,
                 bid_data: DataFrame=None,
                 ask_data: DataFrame=None):
        """
        Initializes a new instance of the TickBuilder class.

        :param precision: The decimal precision for the tick prices (>= 0).
        :param tick_data: The DataFrame containing the tick data.
        :param bid_data: The DataFrame containing the bid bars data.
        :param ask_data: The DataFrame containing the ask bars data.
        :raises: ConditionFailed: If the precision is negative (< 0).
        :raises: ConditionFailed: If the tick_data is a type other than None or DataFrame.
        :raises: ConditionFailed: If the bid_data is a type other than None or DataFrame.
        :raises: ConditionFailed: If the ask_data is a type other than None or DataFrame.
        """
        Condition.not_negative(precision, 'precision')
        Condition.type_or_none(tick_data, DataFrame, 'tick_data')
        Condition.type_or_none(bid_data, DataFrame, 'bid_data')
        Condition.type_or_none(ask_data, DataFrame, 'ask_data')

        self._symbol = symbol
        self._precision = precision
        self._tick_data = with_utc_index(tick_data)
        self._bid_data = with_utc_index(bid_data)
        self._ask_data = with_utc_index(ask_data)

    cpdef list build_ticks_all(self):
        """
        Return the built ticks from the held data.

        :return List[Tick].
        """
        if self._tick_data is not None and len(self._tick_data) > 0:
            return list(map(self._build_tick_from_values,
                            self._tick_data.values,
                            pd.to_datetime(self._tick_data.index)))
        else:
            assert(self._bid_data is not None, 'Insufficient data to build ticks.')
            assert(self._ask_data is not None, 'Insufficient data to build ticks.')

            return list(map(self._build_tick,
                            self._bid_data['close'],
                            self._ask_data['close'],
                            pd.to_datetime(self._bid_data.index)))

    cpdef Tick _build_tick(
            self,
            float bid,
            float ask,
            datetime timestamp):
        # Build a tick from the given values
        return Tick(self._symbol,
                    Price(bid, self._precision),
                    Price(ask, self._precision),
                    timestamp)

    cpdef Tick _build_tick_from_values(self, double[:] values, datetime timestamp):
        # Build a tick from the given values. The function expects the values to
        # be an ndarray with 2 elements [bid, ask] of type double.
        return Tick(self._symbol,
                    Price(values[0], self._precision),
                    Price(values[1], self._precision),
                    timestamp)


cdef class TickBarGenerator:
    """
    Provides generation of tick bars from given data.
    """

    @staticmethod
    def generate(data:pd.DataFrame, int period):
        """
        Return the generated tick bars from the given data.
        Data must have a DateTime index with 'price' and 'volume' columns.

        :param data: The data to generate the tick bars from.
        :param period: The period for each tick bar.
        :return: pd.DataFrame.
        """
        if 'volume' not in data:
            data['volume'] = 1

        cdef int length = round(len(data) // period) * period
        cdef int groups = int(length / period)

        bar_groups = np.split(data[:length], groups, axis=0)
        data = [[
            group.index[-1],
            group['price'][0],
            group['price'].max(),
            group['price'].min(),
            group['price'][-1],
            sum(group['volume'])
        ] for group in bar_groups]

        cdef list columns = ['timestamp', 'open', 'high', 'low', 'close', 'volume']
        tick_bars = pd.DataFrame(data, columns=columns).set_index('timestamp')

        return tick_bars


cdef class BarDataWrangler:
    """
    Provides a means of building lists of bars from a given Pandas DataFrame of
    the correct specification.
    """

    def __init__(self,
                 int precision,
                 int volume_multiple=1,
                 data: DataFrame=None):
        """
        Initializes a new instance of the BarBuilder class.

        :param precision: The decimal precision for bar prices (>= 0).
        :param data: The the bars market data.
        :param volume_multiple: The volume multiple for the builder (> 0).
        :raises: ConditionFailed: If the decimal_precision is negative (< 0).
        :raises: ConditionFailed: If the volume_multiple is not positive (> 0).
        :raises: ConditionFailed: If the data is a type other than DataFrame.
        """
        Condition.not_negative(precision, 'precision')
        Condition.positive(volume_multiple, 'volume_multiple')
        Condition.type(data, DataFrame, 'data')

        self._precision = precision
        self._volume_multiple = volume_multiple
        self._data = with_utc_index(data)

    cpdef list build_databars_all(self):
        """
        Return a list of DataBars from all data.
        
        :return List[DataBar].
        """
        return list(map(self._build_databar,
                        self._data.values,
                        pd.to_datetime(self._data.index)))

    cpdef list build_databars_from(self, int index=0):
        """
        Return a list of DataBars from the given index.
        
        :return List[DataBar].
        """
        Condition.not_negative(index, 'index')

        return list(map(self._build_databar,
                        self._data.iloc[index:].values,
                        pd.to_datetime(self._data.iloc[index:].index)))

    cpdef list build_databars_range(self, int start=0, int end=-1):
        """
        Return a list of DataBars within the given range.
        
        :return List[DataBar].
        """
        Condition.not_negative(start, 'start')

        return list(map(self._build_databar,
                        self._data.iloc[start:end].values,
                        pd.to_datetime(self._data.iloc[start:end].index)))

    cpdef list build_bars_all(self):
        """
        Return a list of Bars from all data.

        :return List[Bar].
        """
        return list(map(self._build_bar,
                        self._data.values,
                        pd.to_datetime(self._data.index)))

    cpdef list build_bars_from(self, int index=0):
        """
        Return a list of Bars from the given index (>= 0).

        :return List[Bar].
        """
        Condition.not_negative(index, 'index')

        return list(map(self._build_bar,
                        self._data.iloc[index:].values,
                        pd.to_datetime(self._data.iloc[index:].index)))

    cpdef list build_bars_range(self, int start=0, int end=-1):
        """
        Return a list of Bars within the given range.

        :return List[Bar].
        """
        Condition.not_negative(start, 'start')

        return list(map(self._build_bar,
                        self._data.iloc[start:end].values,
                        pd.to_datetime(self._data.iloc[start:end].index)))

    cpdef DataBar _build_databar(self, double[:] values, datetime timestamp):
        # Build a DataBar from the given index and values. The function expects the
        # values to be an ndarray with 5 elements [open, high, low, close, volume].
        return DataBar(values[0],
                       values[1],
                       values[2],
                       values[3],
                       values[4] * self._volume_multiple,
                       timestamp)

    cpdef Bar _build_bar(self, double[:] values, datetime timestamp):
        # Build a bar from the given index and values. The function expects the
        # values to be an ndarray with 5 elements [open, high, low, close, volume].
        return Bar(Price(values[0], self._precision),
                   Price(values[1], self._precision),
                   Price(values[2], self._precision),
                   Price(values[3], self._precision),
                   int(values[4] * self._volume_multiple),
                   timestamp)

cdef str BID = 'bid'
cdef str ASK = 'ask'
cdef str POINT = 'point'
cdef str PRICE = 'price'
cdef str MID = 'mid'
cdef str OPEN = 'open'
cdef str HIGH = 'high'
cdef str LOW = 'low'
cdef str CLOSE = 'close'
cdef str VOLUME = 'volume'
cdef str TIMESTAMP = 'timestamp'


cdef class IndicatorUpdater:
    """
    Provides an adapter for updating an indicator with a bar. When instantiated
    with an indicator update method, the updater will inspect the method and
    construct the required parameter list for updates.
    """

    def __init__(self,
                 indicator,
                 input_method: Callable=None,
                 list outputs: List[str]=None):
        """
        Initializes a new instance of the IndicatorUpdater class.

        :param indicator: The indicator for updating.
        :param input_method: The indicators input method.
        :param outputs: The list of the indicators output properties.
        :raises ConditionFailed: If the input_method is not None and not of type Callable.
        """
        Condition.type_or_none(input_method, Callable, 'input_method')

        self._indicator = indicator
        if input_method is None:
            self._input_method = indicator.update
        else:
            self._input_method = input_method

        self._input_params = []

        cdef dict param_map = {
            BID: BID,
            ASK: ASK,
            POINT: CLOSE,
            PRICE: CLOSE,
            MID: CLOSE,
            OPEN: OPEN,
            HIGH: HIGH,
            LOW: LOW,
            CLOSE: CLOSE,
            TIMESTAMP: TIMESTAMP
        }

        for param in inspect.signature(self._input_method).parameters:
            if param == 'self':
                self._include_self = True
            else:
                self._input_params.append(param_map[param])

        if outputs is None or len(outputs) == 0:
            self._outputs = ['value']
        else:
            self._outputs = outputs

    cpdef void update_tick(self, Tick tick) except *:
        """
        Update the indicator with the given tick.
        
        :param tick: The tick to update with.
        """
        cdef str param
        if self._include_self:
            self._input_method(self._indicator, *[tick.__getattribute__(param).value for param in self._input_params])
        else:
            self._input_method(*[tick.__getattribute__(param).value for param in self._input_params])

    cpdef void update_bar(self, Bar bar) except *:
        """
        Update the indicator with the given bar.

        :param bar: The bar to update with.
        """
        cdef str param
        if self._include_self:
            self._input_method(self._indicator, *[bar.__getattribute__(param).value for param in self._input_params])
        else:
            self._input_method(*[bar.__getattribute__(param).value for param in self._input_params])

    cpdef void update_databar(self, DataBar bar) except *:
        """
        Update the indicator with the given data bar.

        :param bar: The bar to update with.
        """
        cdef str param
        self._input_method(*[bar.__getattribute__(param) for param in self._input_params])

    cpdef dict build_features_ticks(self, list ticks):
        """
        Return a dictionary of output features from the given bars data.
        
        :return Dict[str, float].
        """
        cdef dict features = {}
        for output in self._outputs:
            features[output] = []

        cdef Bar bar
        cdef tuple value
        for tick in ticks:
            self.update_tick(tick)
            for value in self._get_values():
                features[value[0]].append(value[1])

        return features

    cpdef dict build_features_bars(self, list bars):
        """
        Return a dictionary of output features from the given bars data.
        
        :return Dict[str, float].
        """
        cdef dict features = {}
        for output in self._outputs:
            features[output] = []

        cdef Bar bar
        cdef tuple value
        for bar in bars:
            self.update_bar(bar)
            for value in self._get_values():
                features[value[0]].append(value[1])

        return features

    cpdef dict build_features_databars(self, list bars):
        """
        Return a dictionary of output features from the given bars data.
        
        :return Dict[str, float].
        """
        cdef dict features = {}
        for output in self._outputs:
            features[output] = []

        cdef DataBar bar
        cdef tuple value
        for bar in bars:
            self.update_databar(bar)
            for value in self._get_values():
                features[value[0]].append(value[1])

        return features

    cdef list _get_values(self):
        # Create a list of the current indicator outputs. The list will contain
        # a tuple of the name of the output and the float value. Returns List[(str, float)].
        return [(output, self._indicator.__getattribute__(output)) for output in self._outputs]


cdef class BarBuilder:
    """
    The base class for all bar builders.
    """

    def __init__(self, BarSpecification bar_spec, bint use_previous_close=False):
        """
        Initializes a new instance of the BarBuilder class.

        :param bar_spec: The bar specification for the builder.
        :param use_previous_close: Set true if the previous close price should
        be the open price of a new bar.
        """
        self.bar_spec = bar_spec
        self.last_update = None
        self.count = 0

        self._open = None
        self._high = None
        self._low = None
        self._close = None
        self._volume = 0
        self._use_previous_close = use_previous_close

    cpdef void update(self, Tick tick, long volume=1):
        cdef Price quote = self._get_price(tick)

        if self._open is None:
            # Initialize builder
            self._open = quote
            self._high = quote
            self._low = quote
        elif quote.value > self._high.value:
            self._high = quote
        elif quote.value < self._low.value:
            self._low = quote

        self._close = quote
        self._volume += volume
        self.count += 1
        self.last_update = tick.timestamp

    cpdef Bar build(self, datetime close_time=None):
        if close_time is None:
            close_time = self.last_update

        cdef Bar bar = Bar(
            open_price=self._open,
            high_price=self._high,
            low_price=self._low,
            close_price=self._close,
            volume=self._volume,
            timestamp=close_time,
            checked=False  # Class logic will prevent invalid bars
        )

        self._reset()
        return bar

    cdef void _reset(self):
        if self._use_previous_close:
            self._open = self._close
            self._high = self._close
            self._low = self._close
        else:
            self._open = None
            self._high = None
            self._low = None
            self._close = None

        self._volume = 0
        self.count = 0

    cdef Price _get_price(self, Tick tick):
        if self.bar_spec.quote_type == QuoteType.MID:
            return Price((tick.bid.value + tick.ask.value) / 2)
        elif self.bar_spec.quote_type == QuoteType.BID:
            return tick.bid
        else:
            return tick.ask
        # Condition: quote_type != QuoteType.LAST checked in BarSpecification