package com.coinbase.walletlink

import android.support.test.InstrumentationRegistry
import android.support.test.runner.AndroidJUnit4
import com.coinbase.store.Store
import com.coinbase.store.models.EncryptedSharedPrefsStoreKey
import com.coinbase.store.models.MemoryStoreKey
import com.coinbase.store.models.SharedPrefsStoreKey
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.launch
import org.junit.Assert
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

data class MockComplexObject(val name: String, val age: Int, val wallets: List<String>) {
    override fun equals(other: Any?): Boolean {
        val obj2 = other as? MockComplexObject ?: return false

        return obj2.age == age && obj2.name == name && obj2.wallets == wallets
    }
}

@RunWith(AndroidJUnit4::class)
class StoreTests {
    @Test
    fun useAppContext() {
        // Context of the app under test.
        val appContext = InstrumentationRegistry.getTargetContext()
        assertEquals("com.coinbase.walletlink", appContext.packageName)
    }

    @Test
    fun testStore() {
        val appContext = InstrumentationRegistry.getTargetContext()
        val store = Store(appContext)
        val stringKey = SharedPrefsStoreKey(id = "string_key", uuid = "id", clazz = String::class.java)
        val boolKey = SharedPrefsStoreKey(id = "bool_key", uuid = "id", clazz = Boolean::class.java)
        val complexObjectKey = SharedPrefsStoreKey(id = "complex_object", clazz = MockComplexObject::class.java)
        val expected = "Hello Android CBStore"
        val expectedComplex = MockComplexObject(name = "hish", age = 37, wallets = listOf("hello", "world"))

        store.set(stringKey, expected)
        store.set(boolKey, false)
        store.set(complexObjectKey, expectedComplex)
        store.set(TestKeys.computedKey(uuid = "random"), "hello")

        store.set(TestKeys.activeUser, "random")

        assertEquals(expected, store.get(stringKey))
        assertEquals(false, store.get(boolKey))
        assertEquals(expectedComplex, store.get(complexObjectKey))
        assertEquals("hello", store.get(TestKeys.computedKey(uuid = "random")))
    }

    @Test
    fun testMemory() {
        val expected = "Memory string goes here"
        val appContext = InstrumentationRegistry.getTargetContext()
        val store = Store(appContext)

        store.set(TestKeys.memoryString, expected)

        assertEquals(expected, store.get(TestKeys.memoryString))
    }

    @Test
    fun testObserver() {
        val expected = "Testing observer"
        val appContext = InstrumentationRegistry.getTargetContext()
        val store = Store(appContext)
        val latchDown = CountDownLatch(1)
        var actual = ""

        GlobalScope.launch {
            store.observe(TestKeys.memoryString)
                .filter { it != null }
                .timeout(6, TimeUnit.SECONDS)
                .subscribe({
                    actual = it.element ?: throw AssertionError("No element found")
                    latchDown.countDown()
                }, { latchDown.countDown() })
        }

        store.set(TestKeys.memoryString, expected)
        latchDown.await()

        assertEquals(expected, actual)
    }

    @Test
    fun encryptStringStoreKeyValue() {
        val expectedText = "Bitcoin + Ethereum"
        val store = Store(InstrumentationRegistry.getTargetContext())

        store.set(TestKeys.encryptedString, expectedText)

        val actual = store.get(TestKeys.encryptedString)

        assertEquals(expectedText, actual)
    }

    @Test
    fun encryptComplexObjectStoreKeyValue() {
        val expected = MockComplexObject(name = "hish", age = 37, wallets = listOf("1234", "2345"))
        val store = Store(InstrumentationRegistry.getTargetContext())

        store.set(TestKeys.encryptedComplexObject, expected)

        val actual = store.get(TestKeys.encryptedComplexObject)

        if (actual == null) {
            Assert.fail("Unable to get encrypted complex object")
            return
        }

        assertEquals(expected.name, actual.name)
        assertEquals(expected.age, actual.age)
        assertEquals(expected.wallets, actual.wallets)
    }

    @Test
    fun encryptArrayStoreKeyValue() {
        val expected = arrayOf("Bitcoin", "Ethereum")
        val store = Store(InstrumentationRegistry.getTargetContext())

        store.set(TestKeys.encryptedArray, expected)

        val actual = store.get(TestKeys.encryptedArray)

        assertArrayEquals(expected, actual)
    }

    @Test
    fun encryptComplexObjectArrayStoreKeyValue() {
        val expected = arrayOf(
            MockComplexObject(name = "hish", age = 37, wallets = listOf("1234", "2345")),
            MockComplexObject(name = "aya", age = 3, wallets = listOf("333"))
        )

        val store = Store(InstrumentationRegistry.getTargetContext())

        store.set(TestKeys.encryptedComplexObjectArray, expected)

        val actual = store.get(TestKeys.encryptedComplexObjectArray)

        assertArrayEquals(expected, actual)
    }
}

class TestKeys {
    companion object {
        val activeUser = SharedPrefsStoreKey(id = "computedKeyX", clazz = String::class.java)

        fun computedKey(uuid: String): SharedPrefsStoreKey<String> {
            return SharedPrefsStoreKey(id = "computedKey", uuid = uuid, clazz = String::class.java)
        }

        val memoryString = MemoryStoreKey(id = "memory_string", clazz = String::class.java)

        val encryptedString = EncryptedSharedPrefsStoreKey(
            id = "encryptedString",
            clazz = String::class.java
        )

        val encryptedComplexObject = EncryptedSharedPrefsStoreKey(
            id = "encrypted_complex_object",
            clazz = MockComplexObject::class.java
        )

        val encryptedArray = EncryptedSharedPrefsStoreKey(id = "encrypted_array", clazz = Array<String>::class.java)

        val encryptedComplexObjectArray = EncryptedSharedPrefsStoreKey(
            id = "encrypted_complex_object_array",
            clazz = Array<MockComplexObject>::class.java
        )
    }
}
