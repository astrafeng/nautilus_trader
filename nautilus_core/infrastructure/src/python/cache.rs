// -------------------------------------------------------------------------------------------------
//  Copyright (C) 2015-2023 Nautech Systems Pty Ltd. All rights reserved.
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

use std::collections::HashMap;

use nautilus_core::python::{to_pyruntime_err, to_pyvalue_err};
use nautilus_model::identifiers::trader_id::TraderId;
use pyo3::{prelude::*, types::PyDict, PyResult};

use crate::{cache::CacheDatabase, redis::RedisCacheDatabase};

#[pymethods]
impl RedisCacheDatabase {
    #[new]
    fn py_new(trader_id: TraderId, config: &PyDict) -> PyResult<Self> {
        let mut config_map = HashMap::new();
        for (key, value) in config {
            // Extract key and value as strings
            let key_str = key.extract::<String>()?;
            let value_str = value.extract::<String>()?;

            // Convert the value to a serde_json::Value
            let value_json: serde_json::Value =
                serde_json::from_str(&value_str).map_err(to_pyvalue_err)?;

            // Insert into the HashMap
            config_map.insert(key_str, value_json);
        }

        match Self::new(trader_id, config_map) {
            Ok(cache) => Ok(cache),
            Err(e) => Err(to_pyruntime_err(e.to_string())),
        }
    }

    #[pyo3(name = "read")]
    fn py_read(&mut self, op_type: String) -> PyResult<Vec<Vec<u8>>> {
        match self.read(op_type) {
            Ok(result) => Ok(result),
            Err(e) => Err(to_pyruntime_err(e)),
        }
    }

    #[pyo3(name = "write")]
    fn py_write(&mut self, op_type: String, payload: Vec<Vec<u8>>) -> PyResult<String> {
        match self.write(op_type, payload) {
            Ok(ok) => Ok(ok),
            Err(e) => Err(to_pyvalue_err(e)),
        }
    }
}
