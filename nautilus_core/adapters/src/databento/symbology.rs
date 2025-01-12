// -------------------------------------------------------------------------------------------------
//  Copyright (C) 2015-2024 Nautech Systems Pty Ltd. All rights reserved.
//  https://nautechsystems.io
//
//  Licensed under the GNU Lesser General Public License Version 3.0 (the "License");
//  You may not use this file except in compliance with the License.
//  You may obtain a copy of the License at https://www.gnu.org/licenses/lgpl-3.0.en.html
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
// -------------------------------------------------------------------------------------------------

use anyhow::{bail, Result};
use databento::dbn;
use dbn::Record;
use indexmap::IndexMap;
use nautilus_model::identifiers::{instrument_id::InstrumentId, symbol::Symbol, venue::Venue};
use ustr::Ustr;

use super::{types::DatabentoPublisher, types::PublisherId};

pub fn parse_nautilus_instrument_id(
    record: &dbn::RecordRef,
    metadata: &dbn::Metadata,
    publishers: &IndexMap<PublisherId, DatabentoPublisher>,
) -> Result<InstrumentId> {
    let (publisher_id, instrument_id, nanoseconds) = match record.rtype()? {
        dbn::RType::Mbo => {
            let msg = record.get::<dbn::MboMsg>().unwrap(); // SAFETY: RType known
            (msg.hd.publisher_id, msg.hd.instrument_id, msg.ts_recv)
        }
        dbn::RType::Mbp0 => {
            let msg = record.get::<dbn::TradeMsg>().unwrap(); // SAFETY: RType known
            (msg.hd.publisher_id, msg.hd.instrument_id, msg.ts_recv)
        }
        dbn::RType::Mbp1 => {
            let msg = record.get::<dbn::Mbp1Msg>().unwrap(); // SAFETY: RType known
            (msg.hd.publisher_id, msg.hd.instrument_id, msg.ts_recv)
        }
        dbn::RType::Mbp10 => {
            let msg = record.get::<dbn::Mbp10Msg>().unwrap(); // SAFETY: RType known
            (msg.hd.publisher_id, msg.hd.instrument_id, msg.ts_recv)
        }
        dbn::RType::Ohlcv1S
        | dbn::RType::Ohlcv1M
        | dbn::RType::Ohlcv1H
        | dbn::RType::Ohlcv1D
        | dbn::RType::OhlcvEod => {
            let msg = record.get::<dbn::OhlcvMsg>().unwrap(); // SAFETY: RType known
            (msg.hd.publisher_id, msg.hd.instrument_id, msg.hd.ts_event)
        }
        _ => bail!("RType is currently unsupported by NautilusTrader"),
    };

    let duration = time::Duration::nanoseconds(nanoseconds as i64);
    let datetime = time::OffsetDateTime::UNIX_EPOCH
        .checked_add(duration)
        .unwrap();
    let date = datetime.date();
    let symbol_map = metadata.symbol_map_for_date(date)?;
    let raw_symbol = symbol_map
        .get(instrument_id)
        .expect("No raw symbol found for {instrument_id}");

    let symbol = Symbol {
        value: Ustr::from(raw_symbol),
    };
    let venue_str = publishers.get(&publisher_id).unwrap().venue.as_str();
    let venue = Venue {
        value: Ustr::from(venue_str),
    };

    Ok(InstrumentId::new(symbol, venue))
}
