# Audio interruption recovery

Earlier builds had two problems: an incoming call or a competing audio app muted the microphone permanently, and a transport lost during the interruption could leave the selected room unusable on return.

The interruption state now records prior microphone intent independently of the SDK's temporary mute. A successful OS resume restores only a previously enabled microphone in the same connected room. A saved mute, removed headset, explicit mic action, room change or account change cancels restoration. Late microphone completions are fenced and muted again; an uncertain failure to mute ends the connection. Camera never restarts automatically.

When the transport is lost during an OS interruption, only the existing selected room can request one fresh authorized join after the interruption ends. The model callback is bound to the original login/room generations; leave, logout and changing rooms invalidate it. If iOS does not allow automatic resume, the existing explicit resume action is required. No stale media credential is replayed.

Unit tests cover nested interruptions, prior mute, OS resume hint, explicit cancellation and room replacement.

Still to check on a physical iPhone: incoming call and return; returning from another audio app; interruption with network loss; muted microphone remains muted; headset removal; leaving/changing room or account during a call. Build success is not this acceptance.

A manual microphone action during a fresh grant/connect cancels automatic microphone restoration through a monotonic user-intent revision, even if that action occurred before the transport became connected.

## Mixing with other apps (November 2026)

A voice room no longer stops when another app plays sound. Opening Instagram, YouTube or music used to interrupt the room's call session. The app then muted the microphone and stopped the audio engine, iOS suspended it in the background, and the server dropped the silent peer. The session now mixes with other apps (`.mixWithOthers`, no ducking) in both the listening (`.playback`) and talking (`.playAndRecord`) states. Other apps' sound plays next to the room, and joining a room no longer pauses them.

LiveKit 2.17.0 cannot be told to do this. Its call presets leave `.mixWithOthers` out on purpose, and `AudioManager.sessionConfiguration` is never read. `RoomAudioSession` (in `RoomMedia.swift`) therefore installs `customConfigureAudioSessionFunc`, the one hook every LiveKit session change passes through. LiveKit still decides when the session is needed: engine start and stop, and the playout handles of Sinema, chat videos and the settings preview. `VoiceSessionPolicy` (RoomsCore) applies the category, mode, IO buffer and activation steps that LiveKit would apply, plus mixing.

Trade-offs to know:
- Echo cancellation runs in software and only hears the room. Another app's sound played on the loudspeaker can reach the microphone, so the room hears it. Headphones avoid this.
- LiveKit warns that a mixable call session needs an engine start retry inside WebRTC. Joining can take a moment longer.
- While a voice room runs, the film in Sinema plays on the mixable call session, so the lock screen may not show its controls.

Phone calls, Siri and alarms still interrupt the room. The recovery above still applies to them.

## Rejoin after the background

If the voice room is lost while the app is in the background, it comes back once when the person returns to the app (`RoomRejoin`, RoomsCore). This happens however long the app was away, and for any connection reason. A suspended app notices the loss only after it resumes. So a connection counts as lost in the background when it starts failing within 45 s of the return, before LiveKit has confirmed it again. The phone-call rejoin above is unchanged. Both paths share these rules:
- No rejoin after an explicit leave, a move, a DM call taking over, or sign-out.
- No rejoin after a server decision: a moderator's "Sesten çıkar" or revoked access (`participantRemoved`), the same account joining from another device (`duplicateIdentity`), or a closed room. These now show their own message.
- No rejoin after a safety teardown (a microphone or camera that could not be stopped).
- The microphone comes back as the person left it, unless they were away 10 minutes or longer (`RoomRejoin.longAbsence`). Away runs from leaving the app until returning to it. After a phone call, it is the length of the call. Then the room still comes back, but the microphone starts off and the voice dock says "Uzun süre uzakta kaldığın için mikrofonun kapalı açıldı." A microphone that was off stays off. A deafened person stays deafened.
- It cannot loop. Only an established connection arms the rejoin. The single join spends it. A join that fails before connecting never arms it again.

## Headset removed and reconnected

Removing a headset still deafens, mutes the microphone and mutes screen-share audio. The person turns sound and microphone back on themselves. Turning room sound back on now also restores screen-share audio that the removal muted. An input chosen in the audio settings that left with the headset is cleared, so it cannot steer the route. On iOS 17, a route can take the session away as an interruption (`routeDisconnected`). Such an interruption may never report its end. The headset's return now ends it and offers "Sesi sürdür".

Still to check on a physical iPhone: Instagram/YouTube/music next to a room (speaker and headphones); joining while music plays; leaving the app with the microphone on and off and returning after a few minutes (microphone as left) and after 10 minutes or more (microphone off, with the notice); a moderator disconnect while the app is in the background; wired and Bluetooth headset removed and reconnected; Sinema and chat video sound in and out of a room.
