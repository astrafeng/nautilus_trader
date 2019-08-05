# -------------------------------------------------------------------------------------------------
# <copyright file="concurrency.pyx" company="Nautech Systems Pty Ltd">
#  Copyright (C) 2015-2019 Nautech Systems Pty Ltd. All rights reserved.
#  The use of this source code is governed by the license as found in the LICENSE.md file.
#  https://nautechsystems.io
# </copyright>
# -------------------------------------------------------------------------------------------------

from cpython cimport pythread
from cpython.exc cimport PyErr_NoMemory
from typing import Callable

from nautilus_trader.core.correctness cimport Condition


cdef class FastRLock:
    """
    Provides a fast, re-entrant lock.

    Under un-congested conditions, the lock is never acquired but only
    counted.  Only when a second thread comes in and notices that the
    lock is needed, it acquires the lock and notifies the first thread
    to release it when it's done. This is made possible by the GIL.
    """

    def __cinit__(self):
        self._owner = -1
        self._count = 0
        self._is_locked = False
        self._pending_requests = 0
        self._real_lock = pythread.PyThread_allocate_lock()
        if self._real_lock is NULL:
            PyErr_NoMemory()

    def __dealloc__(self):
        if self._real_lock is not NULL:
            pythread.PyThread_free_lock(self._real_lock)
            self._real_lock = NULL

    cpdef bint acquire(self, bint blocking=True):
        return lock_lock(self, pythread.PyThread_get_thread_ident(), blocking)

    cpdef void release(self):
        if self._owner != pythread.PyThread_get_thread_ident():
            raise RuntimeError("cannot release un-acquired lock")
        unlock_lock(self)

    def __enter__(self):
        return lock_lock(self, pythread.PyThread_get_thread_ident(), True)

    def __exit__(self, t, v, tb):
        if self._owner != pythread.PyThread_get_thread_ident():
            raise RuntimeError("cannot release un-acquired lock")
        unlock_lock(self)

    cdef bint _is_owned(self):
        return self._owner == pythread.PyThread_get_thread_ident()


cdef inline bint lock_lock(FastRLock lock, long current_thread, bint blocking) nogil:
    # Note that this function *must* hold the GIL when being called.
    # We just use 'nogil' in the signature to make sure that no Python
    # code execution slips in that might free the GIL

    if lock._count:
        # locked! - by myself?
        if current_thread == lock._owner:
            lock._count += 1
            return 1
    elif not lock._pending_requests:
        # not locked, not requested - go!
        lock._owner = current_thread
        lock._count = 1
        return 1
    # need to get the real lock
    return _acquire_lock(
        lock, current_thread,
        pythread.WAIT_LOCK if blocking else pythread.NOWAIT_LOCK)

cdef bint _acquire_lock(FastRLock lock, long current_thread, int wait) nogil:
    # Note that this function *must* hold the GIL when being called.
    # We just use 'nogil' in the signature to make sure that no Python
    # code execution slips in that might free the GIL

    if not lock._is_locked and not lock._pending_requests:
        # someone owns it but didn't acquire the real lock - do that
        # now and tell the owner to release it when done. Note that we
        # do not release the GIL here as we must absolutely be the one
        # who acquires the lock now.
        if not pythread.PyThread_acquire_lock(lock._real_lock, wait):
            return 0
        #assert not lock._is_locked
        lock._is_locked = True
    lock._pending_requests += 1
    with nogil:
        # wait for the lock owning thread to release it
        locked = pythread.PyThread_acquire_lock(lock._real_lock, wait)
    lock._pending_requests -= 1
    #assert not lock._is_locked
    #assert lock._count == 0
    if not locked:
        return 0
    lock._is_locked = True
    lock._owner = current_thread
    lock._count = 1
    return 1

cdef inline void unlock_lock(FastRLock lock) nogil:
    # Note that this function *must* hold the GIL when being called.
    # We just use 'nogil' in the signature to make sure that no Python
    # code execution slips in that might free the GIL

    #assert lock._owner == pythread.PyThread_get_thread_ident()
    #assert lock._count > 0
    lock._count -= 1
    if lock._count == 0:
        lock._owner = -1
        if lock._is_locked:
            pythread.PyThread_release_lock(lock._real_lock)
            lock._is_locked = False


cdef class ConcurrentDictionary:
    """
    Provides a strongly typed thread safe dictionary.
    """

    def __init__(self, type type_key, type type_value):
        """
        Initializes a new instance of the ConcurrentDictionary class.
        """
        Condition.not_none(type_key, 'type_key')
        Condition.not_none(type_value, 'type_value')
        Condition.true(type_key != type(None), 'type_key != NoneType')
        Condition.true(type_value != type(None), 'type_value != NoneType')

        self.type_key = type_key
        self.type_value = type_value
        self._lock = FastRLock()
        self._internal = {}

    def __len__(self):
        """
        Return the number of items in the dictionary.

        :return: int.
        """
        self._lock.acquire()
        cdef int length = len(self._internal)
        self._lock.release()
        return length

    def __enter__(self):
        """
        Context manager enter the block, acquire the lock.
        """
        self._lock.acquire()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        """
        Context manager exit the block, release the lock.
        """
        self._lock.release()

    def __getitem__(self, k):
        Condition.type(k, self.type_key, 'k')
        self._lock.acquire()
        item = self._internal.__getitem__(k)
        self._lock.release()
        return item

    def __setitem__(self, k, v):
        Condition.type(k, self.type_key, 'k')
        Condition.type(v, self.type_value, 'v')
        self._lock.acquire()
        self._internal.__setitem__(k, v)
        self._lock.release()

    def __delitem__(self, k):
        Condition.type(k, self.type_key, 'k')
        self._lock.acquire()
        self._internal.__delitem__(k)
        self._lock.release()

    def __contains__(self, k):
        Condition.type(k, self.type_key, 'k')
        self._lock.acquire()
        result = self._internal.__contains__(k)
        self._lock.release()
        return result

    cpdef object keys(self):
        self._lock.acquire()
        keys = self._internal.keys()
        self._lock.release()
        return keys

    cpdef object values(self):
        self._lock.acquire()
        values = self._internal.values()
        self._lock.release()
        return values

    cpdef object items(self):
        self._lock.acquire()
        items = self._internal.items()
        self._lock.release()
        return items

    cpdef object get(self, k, default=None):
        Condition.type(k, self.type_key, 'k')
        self._lock.acquire()
        item = self._internal.get(k, default)
        self._lock.release()
        return item

    cpdef object setdefault(self, k, default=None):
        Condition.type(k, self.type_key, 'k')
        self._lock.acquire()
        result = self._internal.setdefault(k, default)
        self._lock.release()
        return result

    cpdef object pop(self, k, d=None):
        Condition.type(k, self.type_key, 'k')
        self._lock.acquire()
        item = self._internal.pop(k, d)
        self._lock.release()
        return item

    cpdef object popitem(self):
        self._lock.acquire()
        item = self._internal.popitem()
        self._lock.release()
        return item

    cpdef dict copy(self):
        self._lock.acquire()
        copied = self._internal.copy()
        self._lock.release()
        return copied

    cpdef void clear(self):
        self._lock.acquire()
        self._internal.clear()
        self._lock.release()


cdef class ObjectCache:
    """
    Provides a strongly typed object cache with strings as keys.
    """

    def __init__(self, type type_value, parser: Callable):
        """
        Initializes a new instance of the ObjectCache class.
        """
        Condition.not_none(type_value, 'type_value')
        Condition.true(type_value != type(None), 'type_value != NoneType')
        Condition.type(parser, Callable, 'parser')

        self.type_key = str
        self.type_value = type_value
        self._cache = ConcurrentDictionary(str, type_value)
        self._parser = parser

    cpdef object get(self, str key):
        """
        Return the cached object for the given key otherwise cache and return
        the parsed key.

        :param key: The key to check.
        :return: object.
        """
        parsed = self._cache.get(key, None)

        if parsed is None:
            parsed = self._parser(key)
            self._cache[key] = parsed

        return parsed
