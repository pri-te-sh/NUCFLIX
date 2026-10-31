package com.pritesh.nucflix.phone.data

import android.app.Activity
import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.credentials.ClearCredentialStateRequest
import androidx.credentials.CredentialManager
import androidx.credentials.CustomCredential
import androidx.credentials.GetCredentialRequest
import androidx.credentials.exceptions.GetCredentialCancellationException
import com.google.android.libraries.identity.googleid.GetSignInWithGoogleOption
import com.google.android.libraries.identity.googleid.GoogleIdTokenCredential
import com.google.firebase.FirebaseNetworkException
import com.google.firebase.FirebaseTooManyRequestsException
import com.google.firebase.Timestamp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.auth.FirebaseAuthInvalidCredentialsException
import com.google.firebase.auth.FirebaseAuthInvalidUserException
import com.google.firebase.auth.FirebaseAuthUserCollisionException
import com.google.firebase.auth.FirebaseAuthWeakPasswordException
import com.google.firebase.auth.FirebaseUser
import com.google.firebase.auth.GoogleAuthProvider
import com.google.firebase.auth.userProfileChangeRequest
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.ListenerRegistration
import com.google.firebase.firestore.SetOptions
import com.pritesh.nucflix.phone.BuildConfig
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await
import java.util.Date

/**
 * Firebase session for the household: sign-in, the Xtream lines, the people profiles and the paired TVs.
 * The Android counterpart of the iPhone's CloudAccount (same documents, same rules). Lines are only held in
 * memory; the device keeps just the IDs of the chosen profile and line, which are not secret.
 */
class CloudAccount(context: Context) {
    enum class Phase { STARTING, SIGNED_OUT, SIGNED_IN }

    var phase by mutableStateOf(Phase.STARTING); private set
    var uid by mutableStateOf<String?>(null); private set
    var email by mutableStateOf<String?>(null); private set
    var displayName by mutableStateOf<String?>(null); private set

    var lines by mutableStateOf(emptyList<CloudLine>()); private set
    var profiles by mutableStateOf(emptyList<CloudProfile>()); private set
    var linesLoaded by mutableStateOf(false); private set
    var profilesLoaded by mutableStateOf(false); private set
    var pairedTvs by mutableStateOf(emptyList<PairedTv>()); private set

    var selectedProfileId by mutableStateOf<String?>(null); private set
    var activeLineId by mutableStateOf<String?>(null); private set

    /** The last failed action, worded for the user. */
    var error by mutableStateOf<String?>(null)
    var busy by mutableStateOf(false); private set
    /** A pairing code from a scanned TV QR code, waiting for the user to confirm. */
    var scannedPairCode by mutableStateOf<String?>(null)

    val selectedProfile: CloudProfile? get() = profiles.firstOrNull { it.id == selectedProfileId }
    val activeLine: CloudLine? get() = lines.firstOrNull { it.id == activeLineId } ?: lines.firstOrNull()

    private val auth = FirebaseAuth.getInstance()
    private val db = FirebaseFirestore.getInstance()
    private val prefs = context.getSharedPreferences("nucflix.cloud", Context.MODE_PRIVATE)
    private val credentials = CredentialManager.create(context)
    private val scope = MainScope()
    private val listeners = mutableListOf<ListenerRegistration>()
    private var creatingFirstProfile = false
    /** The server (not just the local cache, which reads as empty while offline) answered for profiles. */
    private var profilesFromServer = false
    /** The name typed at sign-up: the account's display name is saved a moment after the account exists. */
    private var signUpName: String? = null

    init {
        auth.addAuthStateListener { handle(it.currentUser) }
    }

    // ---------------------------------------------------------------- session

    private fun handle(user: FirebaseUser?) {
        if (user?.uid == uid && phase != Phase.STARTING) return
        listeners.forEach { it.remove() }
        listeners.clear()
        lines = emptyList()
        profiles = emptyList()
        pairedTvs = emptyList()
        linesLoaded = false
        profilesLoaded = false
        profilesFromServer = false
        if (user == null || user.isAnonymous) {
            uid = null
            email = null
            displayName = null
            selectedProfileId = null
            activeLineId = null
            phase = Phase.SIGNED_OUT
            return
        }
        uid = user.uid
        email = user.email
        displayName = user.displayName
        selectedProfileId = prefs.getString(profileKey(user.uid), null)
        activeLineId = prefs.getString(lineKey(user.uid), null)
        phase = Phase.SIGNED_IN
        startListening(user.uid)
    }

    private fun startListening(uid: String) {
        val user = db.collection("users").document(uid)
        // Written only when the name changed (it used to be rewritten on every launch).
        user.get().addOnSuccessListener { snap ->
            val name = displayName ?: email ?: "NucFlix"
            if (snap.getString("name") != name) {
                user.set(mapOf("name" to name, "updatedAt" to FieldValue.serverTimestamp()), SetOptions.merge())
            }
        }
        listeners += user.collection("lines").addSnapshotListener { snap, _ ->
            if (snap == null || this.uid != uid) return@addSnapshotListener
            lines = snap.documents.mapNotNull { CloudLine.from(it.id, it.data ?: emptyMap()) }
                .sortedBy { it.name.lowercase() }
            // An empty answer from the cache (a slow start) isn't "no lines": wait for the server.
            if (!snap.metadata.isFromCache || !snap.isEmpty) linesLoaded = true
            ensureFirstProfile()
        }
        listeners += user.collection("members").addSnapshotListener { snap, _ ->
            if (snap == null || this.uid != uid) return@addSnapshotListener
            pairedTvs = snap.documents.map {
                PairedTv(it.id, it.getString("name") ?: "Fire TV", it.getTimestamp("pairedAt")?.toDate())
            }.sortedByDescending { it.pairedAt ?: Date(0) }
        }
        listeners += user.collection("profiles").addSnapshotListener { snap, _ ->
            if (snap == null || this.uid != uid) return@addSnapshotListener
            profiles = snap.documents.mapNotNull { CloudProfile.from(it.id, it.data ?: emptyMap()) }
                .sortedWith(compareBy({ it.order }, { it.name }))
            if (!snap.metadata.isFromCache || !snap.isEmpty) profilesLoaded = true
            if (!snap.metadata.isFromCache) profilesFromServer = true
            // Only the server can say a profile was deleted (the cache reads as empty on a slow start).
            if (profilesFromServer && selectedProfileId != null && profiles.none { it.id == selectedProfileId }) selectProfile(null)
            ensureFirstProfile()
        }
    }

    fun selectProfile(id: String?) {
        selectedProfileId = id
        uid?.let { prefs.edit().putString(profileKey(it), id).apply() }
    }

    fun selectLine(id: String?) {
        activeLineId = id
        uid?.let { prefs.edit().putString(lineKey(it), id).apply() }
    }

    private fun profileKey(uid: String) = "nucflix.cloud.profile.$uid"
    private fun lineKey(uid: String) = "nucflix.cloud.line.$uid"

    // ---------------------------------------------------------------- sign-in

    suspend fun signIn(email: String, password: String) {
        run { auth.signInWithEmailAndPassword(email.trim(), password).await() }
    }

    suspend fun signUp(name: String, email: String, password: String) {
        signUpName = name.trim()
        run {
            val result = auth.createUserWithEmailAndPassword(email.trim(), password).await()
            result.user?.updateProfile(userProfileChangeRequest { displayName = name.trim() })?.await()
            displayName = name.trim()
        }
    }

    suspend fun sendPasswordReset(email: String): Boolean =
        run { auth.sendPasswordResetEmail(email.trim()).await(); true } ?: false

    /** Google account picker (Credential Manager) -> Firebase sign-in with the returned ID token. */
    suspend fun signInWithGoogle(activity: Activity) {
        run {
            val option = GetSignInWithGoogleOption.Builder(BuildConfig.FIREBASE_WEB_CLIENT_ID).build()
            val request = GetCredentialRequest.Builder().addCredentialOption(option).build()
            val credential = credentials.getCredential(activity, request).credential
            if (credential !is CustomCredential || credential.type != GoogleIdTokenCredential.TYPE_GOOGLE_ID_TOKEN_CREDENTIAL) {
                throw CloudError("Google didn't return a sign-in token. Please try again.")
            }
            val idToken = GoogleIdTokenCredential.createFrom(credential.data).idToken
            auth.signInWithCredential(GoogleAuthProvider.getCredential(idToken, null)).await()
        }
    }

    fun signOut() {
        auth.signOut()
        scope.launch { runCatching { credentials.clearCredentialState(ClearCredentialStateRequest()) } }
    }

    // ---------------------------------------------------------------- lines

    /**
     * Checks the line with the provider first, so only working logins (with the scheme that actually works,
     * https or http) are saved.
     */
    suspend fun saveLine(id: String?, name: String, serverUrl: String, username: String, password: String): CloudLine? {
        val uid = uid ?: return null
        val saved = run {
            val base = Xtream.verify(serverUrl, username.trim(), password)
            val col = db.collection("users").document(uid).collection("lines")
            val ref = if (id != null) col.document(id) else col.document()
            val data = mutableMapOf<String, Any>(
                "name" to name.trim(), "serverURL" to base, "username" to username.trim(), "password" to password,
                "updatedAt" to FieldValue.serverTimestamp()
            )
            if (id == null) data["createdAt"] = FieldValue.serverTimestamp()
            ref.set(data, SetOptions.merge()).await()
            CloudLine(ref.id, name.trim(), base, username.trim(), password)
        }
        if (saved != null && activeLineId == null) selectLine(saved.id)
        return saved
    }

    suspend fun deleteLine(line: CloudLine) {
        val uid = uid ?: return
        run { db.collection("users").document(uid).collection("lines").document(line.id).delete().await() }
        if (activeLineId == line.id) selectLine(null)
    }

    // ---------------------------------------------------------------- profiles

    suspend fun saveProfile(id: String?, name: String, avatar: String, kids: Boolean): String? {
        val uid = uid ?: return null
        val col = db.collection("users").document(uid).collection("profiles")
        val ref = if (id != null) col.document(id) else col.document()
        val data = mutableMapOf<String, Any>(
            "name" to name.trim().take(40), "avatar" to avatar, "kids" to kids, "updatedAt" to FieldValue.serverTimestamp()
        )
        if (id == null) {
            data["createdAt"] = FieldValue.serverTimestamp()
            data["order"] = (profiles.maxOfOrNull { it.order } ?: -1) + 1
            data["prefs"] = mapOf("autoplayNext" to true)
        }
        return run { ref.set(data, SetOptions.merge()).await(); ref.id }
    }

    /** Turns Profile Lock on (a PIN's hash, see CloudProfile.pinHash) or off (empty). */
    suspend fun setProfilePin(profile: CloudProfile, hash: String) {
        val uid = uid ?: return
        val ref = db.collection("users").document(uid).collection("profiles").document(profile.id)
        run { ref.set(mapOf("prefs" to mapOf("pinHash" to hash), "updatedAt" to FieldValue.serverTimestamp()), SetOptions.merge()).await() }
    }

    /** Writes some of the profile's synced settings (keys of its prefs map), e.g. mapOf("showAdult" to true). */
    fun savePrefs(profile: CloudProfile, prefs: Map<String, Any>) {
        val uid = uid ?: return
        db.collection("users").document(uid).collection("profiles").document(profile.id)
            .set(mapOf("prefs" to prefs, "updatedAt" to FieldValue.serverTimestamp()), SetOptions.merge())
    }

    /** Deletes the profile and everything it watched or saved. */
    suspend fun deleteProfile(profile: CloudProfile) {
        val uid = uid ?: return
        val ref = db.collection("users").document(uid).collection("profiles").document(profile.id)
        run {
            for (sub in listOf("progress", "favorites")) {
                val docs = ref.collection(sub).get().await().documents
                docs.chunked(400).forEach { chunk ->
                    val batch = db.batch()
                    chunk.forEach { batch.delete(it.reference) }
                    batch.commit().await()
                }
            }
            ref.delete().await()
        }
        if (selectedProfileId == profile.id) selectProfile(null)
    }

    /**
     * A brand-new account gets one profile named after the signed-in person. Only once the server says there
     * are none: a slow or offline start first reports an empty list from the local cache.
     */
    private fun ensureFirstProfile() {
        if (uid == null || !linesLoaded || !profilesFromServer || profiles.isNotEmpty() || creatingFirstProfile) return
        creatingFirstProfile = true
        val first = (signUpName ?: displayName ?: email ?: "Me").split(' ', '@').firstOrNull { it.isNotBlank() } ?: "Me"
        scope.launch {
            saveProfile(null, first, "red", false)
            creatingFirstProfile = false
        }
    }

    // ---------------------------------------------------------------- Fire TV pairing

    /**
     * Approves the code a Fire TV is showing: adds the TV as a member of this household and marks the code
     * approved, in one batch (the security rules require both). Returns the TV's name.
     */
    suspend fun approvePairing(raw: String): String? {
        val uid = uid ?: return null
        val code = raw.uppercase().filter { it.isLetterOrDigit() }
        if (code.length != 8) {
            error = "Enter the 8-character code shown on your TV."
            return null
        }
        return run {
            val ref = db.collection("pairing").document(code)
            val snap = ref.get().await()
            if (!snap.exists()) throw CloudError("No TV is showing that code. Check the code on the TV, or choose New Code there.")
            val tvUid = snap.getString("tvUid")
            if (snap.getString("status") != "pending" || tvUid == null) {
                throw CloudError("That code has already been used. Choose New Code on the TV.")
            }
            val expires = snap.get("expiresAt") as? Timestamp
            if (expires != null && expires.toDate().before(Date())) {
                throw CloudError("That code has expired. Choose New Code on the TV.")
            }
            val name = snap.getString("tvName")?.takeIf { it.isNotEmpty() } ?: "Fire TV"
            val batch = db.batch()
            batch.set(
                db.collection("users").document(uid).collection("members").document(tvUid),
                mapOf("name" to name.take(80), "platform" to "firetv", "pairedAt" to FieldValue.serverTimestamp())
            )
            batch.update(
                ref, mapOf(
                    "status" to "approved", "ownerUid" to uid,
                    "ownerName" to (displayName ?: email ?: "NucFlix").take(80),
                    "approvedAt" to FieldValue.serverTimestamp()
                )
            )
            batch.commit().await()
            name
        }
    }

    /** Unpairs a TV: it loses access at once (and drops back to its pairing code); its presence goes too. */
    suspend fun removeTv(tv: PairedTv) {
        val uid = uid ?: return
        val user = db.collection("users").document(uid)
        run {
            val batch = db.batch()
            batch.delete(user.collection("members").document(tv.id))
            batch.delete(user.collection("devices").document(tv.id))
            batch.commit().await()
        }
    }

    // ---------------------------------------------------------------- helpers

    /** Runs a cloud call with the busy flag set; a failure becomes a readable `error` and returns null. */
    private suspend fun <T> run(work: suspend () -> T): T? {
        busy = true
        error = null
        return try {
            work()
        } catch (e: GetCredentialCancellationException) {
            null // the user closed the Google account picker
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            error = describe(e)
            null
        } finally {
            busy = false
        }
    }

    private fun describe(e: Exception): String = when (e) {
        is CloudError -> e.message ?: "Something went wrong."
        is FirebaseAuthWeakPasswordException -> "Choose a password with at least 6 characters."
        is FirebaseAuthUserCollisionException -> "An account with this email already exists. Sign in instead."
        is FirebaseAuthInvalidUserException -> "That email and password don't match an account."
        is FirebaseAuthInvalidCredentialsException ->
            if (e.errorCode == "ERROR_INVALID_EMAIL") "That doesn't look like a valid email address."
            else "That email and password don't match an account."
        is FirebaseNetworkException, is java.io.IOException -> "No connection. Check your internet and try again."
        is FirebaseTooManyRequestsException -> "Too many attempts. Wait a moment and try again."
        else -> e.localizedMessage ?: "Something went wrong."
    }
}
