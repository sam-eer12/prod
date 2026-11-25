package org.brokbot.android.core.auth

import android.app.Activity
import android.content.Context
import androidx.credentials.ClearCredentialStateRequest
import androidx.credentials.CredentialManager
import androidx.credentials.CustomCredential
import androidx.credentials.GetCredentialRequest
import androidx.credentials.exceptions.GetCredentialCancellationException
import androidx.credentials.exceptions.NoCredentialException
import com.google.android.gms.tasks.Task
import com.google.android.libraries.identity.googleid.GetGoogleIdOption
import com.google.android.libraries.identity.googleid.GoogleIdTokenCredential
import com.google.firebase.FirebaseApp
import com.google.firebase.auth.AuthResult
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.auth.FirebaseUser
import com.google.firebase.auth.GoogleAuthProvider
import com.google.firebase.auth.OAuthProvider
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.suspendCancellableCoroutine
import java.security.MessageDigest
import java.security.SecureRandom
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

data class BrokAuthUser(
    val uid: String,
    val email: String?,
    val displayName: String?,
    val providerId: String
) {
    val providerLabel: String
        get() = when (providerId) {
            "google.com" -> "Google"
            "apple.com" -> "Apple"
            else -> providerId
        }
}

data class BrokAuthState(
    val user: BrokAuthUser? = null,
    val isLoading: Boolean = false,
    val errorMessage: String? = null,
    val statusMessage: String? = null
)

data class BrokAuthNonce(
    val rawNonce: String,
    val sha256Hex: String
) {
    companion object {
        private val charset = "0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._".toCharArray()

        fun generate(length: Int = 32): BrokAuthNonce {
            val random = SecureRandom()
            val raw = buildString(length) {
                repeat(length.coerceAtLeast(16)) {
                    append(charset[random.nextInt(charset.size)])
                }
            }
            return fromRawNonce(raw)
        }

        fun fromRawNonce(rawNonce: String): BrokAuthNonce {
            val digest = MessageDigest.getInstance("SHA-256").digest(rawNonce.toByteArray(Charsets.UTF_8))
            val hex = digest.joinToString("") { "%02x".format(it) }
            return BrokAuthNonce(rawNonce = rawNonce, sha256Hex = hex)
        }
    }
}

class BrokAuthManager(context: Context) {
    private val appContext = context.applicationContext
    private val _authStateFlow = MutableStateFlow(BrokAuthState())
    val authStateFlow: StateFlow<BrokAuthState> = _authStateFlow.asStateFlow()

    private val firebaseAuth: FirebaseAuth? by lazy {
        runCatching {
            if (FirebaseApp.getApps(appContext).isEmpty()) {
                FirebaseApp.initializeApp(appContext)
            }
            if (FirebaseApp.getApps(appContext).isNotEmpty()) {
                FirebaseAuth.getInstance()
            } else {
                null
            }
        }.getOrNull()
    }

    init {
        firebaseAuth?.let { auth ->
            _authStateFlow.value = BrokAuthState(user = auth.currentUser?.toBrokAuthUser())
            auth.addAuthStateListener { updatedAuth ->
                val current = _authStateFlow.value
                _authStateFlow.value = current.copy(
                    user = updatedAuth.currentUser?.toBrokAuthUser()
                )
            }
        }
    }

    suspend fun signInWithGoogle(activity: Activity) {
        val auth = firebaseAuth ?: run {
            _authStateFlow.value = _authStateFlow.value.copy(
                errorMessage = "Firebase is not configured. Check google-services.json."
            )
            return
        }

        val webClientIdRes = appContext.resources.getIdentifier(
            "default_web_client_id",
            "string",
            appContext.packageName
        )
        val webClientId = if (webClientIdRes != 0) appContext.getString(webClientIdRes) else ""
        if (webClientId.isBlank()) {
            _authStateFlow.value = _authStateFlow.value.copy(
                errorMessage = "Missing default_web_client_id from google-services.json."
            )
            return
        }

        _authStateFlow.value = _authStateFlow.value.copy(
            isLoading = true,
            errorMessage = null,
            statusMessage = "Opening Google Sign-In…"
        )

        try {
            val nonce = BrokAuthNonce.generate()
            val googleIdOption = GetGoogleIdOption.Builder()
                .setFilterByAuthorizedAccounts(false)
                .setServerClientId(webClientId)
                .setAutoSelectEnabled(false)
                .setNonce(nonce.sha256Hex)
                .build()

            val request = GetCredentialRequest.Builder()
                .addCredentialOption(googleIdOption)
                .build()

            val credentialManager = CredentialManager.create(activity)
            val result = credentialManager.getCredential(
                request = request,
                context = activity
            )

            val credential = result.credential
            if (credential is CustomCredential &&
                credential.type == GoogleIdTokenCredential.TYPE_GOOGLE_ID_TOKEN_CREDENTIAL
            ) {
                val googleCredential = GoogleIdTokenCredential.createFrom(credential.data)
                val firebaseCredential = GoogleAuthProvider.getCredential(googleCredential.idToken, null)
                val authResult = auth.signInWithCredential(firebaseCredential).awaitResult()
                val signedIn = authResult.user?.toBrokAuthUser()
                _authStateFlow.value = BrokAuthState(
                    user = signedIn,
                    isLoading = false,
                    statusMessage = "Signed in with Google."
                )
            } else {
                _authStateFlow.value = _authStateFlow.value.copy(
                    isLoading = false,
                    errorMessage = "Unexpected credential type returned by Google."
                )
            }
        } catch (_: GetCredentialCancellationException) {
            _authStateFlow.value = _authStateFlow.value.copy(
                isLoading = false,
                statusMessage = "Google Sign-In cancelled."
            )
        } catch (_: NoCredentialException) {
            _authStateFlow.value = _authStateFlow.value.copy(
                isLoading = false,
                errorMessage = "No Google account available on this device or Google Play Services is unavailable."
            )
        } catch (t: Throwable) {
            _authStateFlow.value = _authStateFlow.value.copy(
                isLoading = false,
                errorMessage = t.localizedMessage ?: "Google Sign-In failed."
            )
        }
    }

    suspend fun signInWithApple(activity: Activity) {
        val auth = firebaseAuth ?: run {
            _authStateFlow.value = _authStateFlow.value.copy(
                errorMessage = "Firebase is not configured. Check google-services.json."
            )
            return
        }

        _authStateFlow.value = _authStateFlow.value.copy(
            isLoading = true,
            errorMessage = null,
            statusMessage = "Opening Sign in with Apple…"
        )

        try {
            val provider = OAuthProvider.newBuilder("apple.com")
                .setScopes(listOf("email", "name"))
                .build()

            val pendingTask = auth.pendingAuthResult
            val authResult: AuthResult = if (pendingTask != null) {
                pendingTask.awaitResult()
            } else {
                auth.startActivityForSignInWithProvider(activity, provider).awaitResult()
            }

            _authStateFlow.value = BrokAuthState(
                user = authResult.user?.toBrokAuthUser(),
                isLoading = false,
                statusMessage = "Signed in with Apple."
            )
        } catch (t: Throwable) {
            _authStateFlow.value = _authStateFlow.value.copy(
                isLoading = false,
                errorMessage = t.localizedMessage ?: "Apple Sign-In failed."
            )
        }
    }

    suspend fun signOut(context: Context) {
        firebaseAuth?.signOut()
        runCatching {
            CredentialManager.create(context).clearCredentialState(ClearCredentialStateRequest())
        }
        _authStateFlow.value = BrokAuthState(
            user = null,
            isLoading = false,
            statusMessage = "Signed out."
        )
    }

    private fun FirebaseUser.toBrokAuthUser(): BrokAuthUser {
        val federatedProvider = providerData
            .firstOrNull { it.providerId != "firebase" }
            ?.providerId
            ?: providerId
        return BrokAuthUser(
            uid = uid,
            email = email,
            displayName = displayName,
            providerId = federatedProvider
        )
    }
}

private suspend fun <T> Task<T>.awaitResult(): T = suspendCancellableCoroutine { continuation ->
    addOnSuccessListener { result ->
        if (continuation.isActive) {
            continuation.resume(result)
        }
    }
    addOnFailureListener { exception ->
        if (continuation.isActive) {
            continuation.resumeWithException(exception)
        }
    }
    addOnCanceledListener {
        if (continuation.isActive) {
            continuation.cancel()
        }
    }
}
