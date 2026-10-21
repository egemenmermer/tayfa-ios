# Audio interruption recovery

Earlier builds had two problems: an incoming call or a competing audio app muted the microphone permanently, and a transport lost during the interruption could leave the selected room unusable on return.

The interruption state now records prior microphone intent independently of the SDK's temporary mute. A successful OS resume restores only a previously enabled microphone in the same connected room. A saved mute, removed headset, explicit mic action, room change or account change cancels restoration. Late microphone completions are fenced and muted again; an uncertain failure to mute ends the connection. Camera never restarts automatically.

When the transport is lost during an OS interruption, only the existing selected room can request one fresh authorized join after the interruption ends. The model callback is bound to the original login/room generations; leave, logout and changing rooms invalidate it. If iOS does not allow automatic resume, the existing explicit resume action is required. No stale media credential is replayed.

Unit tests cover nested interruptions, prior mute, OS resume hint, explicit cancellation and room replacement.

Still to check on a physical iPhone: incoming call and return; returning from another audio app; interruption with network loss; muted microphone remains muted; headset removal; leaving/changing room or account during a call. Build success is not this acceptance.

A manual microphone action during a fresh grant/connect cancels automatic microphone restoration through a monotonic user-intent revision, even if that action occurred before the transport became connected.
