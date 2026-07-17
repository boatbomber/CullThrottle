# The Math Behind CullThrottle

[SYSTEM.md](./SYSTEM.md) explains what CullThrottle does each frame and why each mechanism exists. This document is the companion that shows the work: the exact formulas, where they come from, and the arguments for why they're sound. Read SYSTEM.md first, since this document leans on its vocabulary (voxels, buckets, search volumes, proofs, the motion odometers) and mostly doesn't redefine it. The one refinement is the word slack. SYSTEM.md uses it for every number that rides along with a verdict, but the math here needs to tell those numbers apart, so clearance becomes the umbrella term, slack means the clearance of an inside verdict, margin means the clearance of an outside one, and exit clearance belongs to straddles. Section 5 makes all three precise.

## 1. What "correct" means here

CullThrottle approximates constantly, so correctness can't mean exactness. This document defends a narrower claim. Every approximation errs in a known direction, and the directions are chosen so the system never hides something it should show.

1. A voxel or bucket reported culled is outside the view frustum or hidden behind a tagged occluder, up to float tolerances that are themselves padded against (section 10).
2. A voxel reported visible may sit a little outside the view. Over-inclusion costs a little wasted work, never a visual bug, and is accepted everywhere.
3. A cached verdict may expire sooner than the math strictly requires, never later.
4. The one deliberate exception is the search's budget fallback, which reuses stale verdicts when time runs out. It's metered, fed to the render distance controller, and spread across regions by the fairness rotation. Section 11 pins down what it can get wrong.

Throughout, $S$ is the voxel size in studs (100 by default), $c$ is the camera position, and a plane is a pair $(p, n)$ of a point on the plane and a unit outward normal. The signed distance from a point $x$ to a plane is

$$f(x) = (x - p) \cdot n$$

with the convention that normals point out of the frustum, so positive distance means outside.

## Part I: The geometry

### 2. Voxel coordinates

An object whose position is $p$ lives in the voxel with integer key $k = \lfloor p / S \rfloor$, taken componentwise. That voxel covers the world-space cube $[kS, (k+1)S)$ per axis, which in voxel coordinates (world coordinates divided by $S$) is $[k, k+1)$. Every box the search tests is one of these half-open integer boxes or a union of them, with ordered bounds ($x_0 \le x_1$ and so on).

The frustum planes are built once per frame directly in voxel coordinates by dividing the plane positions by $S$ and leaving the normals alone. That works because signed distance scales uniformly:

$$\left(\tfrac{x}{S} - \tfrac{p}{S}\right) \cdot n = \frac{(x - p) \cdot n}{S}.$$

Signs are preserved, so every verdict is unchanged, and every clearance comes out in voxel units, the unit the motion odometers charge in. Normals are unit length before and after because uniform scaling doesn't rotate directions.

### 3. Building the five frustum planes

The camera reports `MaxAxisFieldOfView`, the full field of view across the larger viewport axis. With viewport aspect ratio $a$ (width over height), the vertical and horizontal half-angles $\theta_v$ and $\theta_h$ satisfy

$$\tan\theta_v = \frac{\tan(\mathrm{FOV}_{max}/2)}{\max(a, 1)}, \qquad \tan\theta_h = a \tan\theta_v.$$

The first formula reads off which axis the camera is reporting. On a tall viewport the max axis already is vertical, so $\theta_v$ is $\mathrm{FOV}_{max}/2$ directly. On a wide viewport ($a > 1$) the max axis is horizontal, so $\mathrm{FOV}_{max}/2$ is $\theta_h$, and dividing its tangent by $a$ recovers the vertical half-angle through the standard projection relation $\tan\theta_h = a\tan\theta_v$. At render distance $d$, the far plane is the rectangle of half-height $H = d\tan\theta_v$ and half-width $W = aH$, centered $d$ studs down the look vector.

Each side plane contains the camera position and one edge of that far rectangle, so its normal is the cross product of the camera's up vector (for left and right) or right vector (for top and bottom) with the edge-to-camera direction, normalized and oriented outward. Writing $\hat{R}, \hat{U}, \hat{F}$ for the camera's right, up, and look vectors, the resulting normals have a clean closed form in the camera basis:

$$n_{right} = \hat{R}\cos\theta_h - \hat{F}\sin\theta_h, \qquad n_{left} = -\hat{R}\cos\theta_h - \hat{F}\sin\theta_h,$$

$$n_{top} = \hat{U}\cos\theta_v - \hat{F}\sin\theta_v, \qquad n_{bottom} = -\hat{U}\cos\theta_v - \hat{F}\sin\theta_v.$$

You can sanity-check the orientation with a probe point straight ahead. For $x = c + D\hat{F}$, the distance to the right plane is $D\hat{F} \cdot n_{right} = -D\sin\theta_h < 0$, correctly inside. These closed forms come back twice more, once for projection changes (section 6) and once for the per-object cull (section 16). The fifth plane is the far plane, passing through the far rectangle's center with normal $\hat{F}$, so points beyond the render distance get positive (outside) distance.

The frustum with no near plane is the pyramid from the camera apex to the far rectangle, which is the convex hull of five points, the apex and the four far corners. The axis-aligned bounding box of a convex hull is the componentwise min and max of its generating points, so the search's frustum AABB is computed from exactly those five points, floored into voxel indices (with one added to the max side to form the half-open query box).

### 4. Why there is no near plane

The four side planes all pass through the camera position, and that makes a near plane redundant. Take any point at position $c - a\hat{F} + b\hat{R} + e\hat{U}$ with $a > 0$, meaning strictly behind the camera. Its signed distances to the right and left planes are

$$f_{right} = b\cos\theta_h + a\sin\theta_h, \qquad f_{left} = -b\cos\theta_h + a\sin\theta_h,$$

which sum to $2a\sin\theta_h$. Since the field of view is under 180 degrees, $\sin\theta_h > 0$, so the sum is strictly positive and at least one of the two distances is positive. Every point behind the camera is therefore already outside the left or right plane (or both), and a near-plane test would reject nothing new.

### 5. The box test

`Frustum.isBoxInFrustum` classifies a voxel-space box against the planes. Write the box as center $m$ and half-extents $e = (e_x, e_y, e_z)$. For one plane, let $d = (m - p) \cdot n$ be the center's signed distance.

The exact tool is the box's projection radius onto the plane normal,

$$r = e_x \lvert n_x \rvert + e_y \lvert n_y \rvert + e_z \lvert n_z \rvert.$$

This is the support function of the box in direction $n$. Each coordinate of a box point ranges over $[m_i - e_i,\ m_i + e_i]$ independently, so the maximum of $(x - m)\cdot n$ over the box is reached by picking each coordinate at the extreme matching the sign of $n_i$, which gives exactly $r$, and the minimum is $-r$ by symmetry. So the box's signed distances to the plane fill the interval $[d - r,\ d + r]$. Everything below follows from looking at that interval.

Before computing $r$, the test tries the circumscribing sphere, whose radius is $\rho = \lvert e \rvert$. Writing $r = e \cdot (\lvert n_x \rvert, \lvert n_y \rvert, \lvert n_z \rvert)$ and applying Cauchy-Schwarz with $\lvert n \rvert = 1$ gives $r \le \rho$, so sphere verdicts are valid box verdicts and the cheap check can settle the clear cases. With a guard band $\varepsilon = 10^{-4}$ voxels, the per-plane outcomes are these.

1. If $d > \rho + \varepsilon$ (sphere shortcut) or $d > r + \varepsilon$ (exact), the box is entirely outside this plane, hence outside the frustum. The reported rejection margin is $d - \rho - \varepsilon$ or $d - r - \varepsilon$, both understatements of the true clearance $d - r$, which is the safe direction for a stored proof.
2. If $d \le -\rho$ (sphere shortcut) or $d + r \le \varepsilon$ (exact), the box is entirely inside this plane. The slack is $-d - \rho$ or $-(d + r)$, again at most the true distance-to-touching, and again safe. In the exact case the box may poke up to $\varepsilon$ past the plane while being called fully inside. That misjudgment is at most $10^{-4}$ voxels (a hundredth of a stud at default scale), it errs toward calling things visible, and the slack it stores is then negative and clamps to zero, so the generous verdict gets no durability.
3. Otherwise the box straddles the plane. The plane's bit is set in the returned straddle mask, and the test records the exit clearance $r + \varepsilon - d$, how much $d$ would have to grow before case 1 could fire. Until that much motion accumulates, the box still has a foot inside this plane.

The box intersects the frustum when no tested plane lands in case 1. The slack reported alongside an intersect verdict is the minimum of the case 2 slacks, kept separately for the side planes and the far plane because a render distance change moves only the far plane (voxel proofs merge the two in section 8, while bucket verdicts keep them apart in section 9). A box hugging the frustum's exterior near an edge or corner can pass the conservative "Not fully outside any single plane" frustum test while being outside the true frustum. The error direction is inclusion, the cost is a few falsely visible voxels near the silhouette, and the per-object cull during ingest (section 16) catches most of what slips through.

`Frustum.classifyBucket` is the same core run with all five planes enabled, repackaged into the three bucket states. Fully outside and fully inside are durable verdicts with clearances and get cached. A straddling bucket gets no cached verdict at all, because no positive clearance backs either durable verdict for the whole box (some of its content is one hair's motion from flipping), so it's re-searched for as long as it straddles.

## Part II: The motion proofs

### 6. How far can a plane sweep?

A cached verdict with clearance $s$ stays true as long as no plane's signed distance to the proven region has changed by $s$ or more. So everything rests on bounding how far camera motion can move the value $f(x) = (x - p) \cdot n$ for a fixed world point $x$. There are four motion sources, and each gets a bound.

When the camera translates by $t$, every plane is carried rigidly, so $p$ becomes $p + t$ while $n$ is unchanged, and

$$f'(x) - f(x) = -t \cdot n, \qquad \lvert f'(x) - f(x) \rvert \le \lvert t \rvert.$$

Translation charges at face value, one voxel of motion sweeps a plane at most one voxel.

When the camera rotates by angle $\varphi$ (the full axis-angle of the orientation delta, so roll counts), every plane pivots about the camera position. A side plane passes through $c$, so $p = c$ and only its normal moves, from $n$ to $Rn$. Then

$$\lvert f'(x) - f(x) \rvert = \lvert (x - c) \cdot (Rn - n) \rvert \le \lvert x - c \rvert \cdot \lvert Rn - n \rvert = \lvert x - c \rvert \cdot 2\sin(\varphi/2) \le \lvert x - c \rvert \, \varphi.$$

The far plane passes through $c + d_f\hat{F}$ with normal $\hat{F}$, so $f(x) = (x - c)\cdot\hat{F} - d_f$ and the same algebra gives the same bound. This is the lighthouse-beam fact made precise. A rotation sweeps planes in proportion to the arm, the distance from the camera to the point in question, and the small-angle inequality $2\sin(\varphi/2) \le \varphi$ keeps the charge an overestimate.

When the render distance changes by $\Delta d_f$ voxels, the far plane slides along the look vector and $f(x) = (x-c)\cdot\hat{F} - d_f$ changes by exactly $\lvert \Delta d_f \rvert$, while the four side planes don't move at all. That's why this source gets its own odometer.

When the field of view or aspect ratio changes, look back at the closed forms in section 3. Each side normal is a function of one half-angle, tracing a circle in a fixed plane through $c$, so a half-angle change of $\Delta\theta$ pivots that plane about the camera by exactly $\lvert \Delta\theta \rvert$, and the far plane doesn't move. A projection change is therefore charged to the rotation odometer as $\max(\lvert \Delta\theta_v \rvert, \lvert \Delta\theta_h \rvert)$, which is at least each individual plane's swing.

A single frame combines rotation and translation. Composing the two bounds,

$$\lvert f'(x) - f(x) \rvert \;\le\; \lvert x - c \rvert\,\varphi + \lvert t \rvert,$$

and across multiple frames the per-frame charges add up by the triangle inequality, which is what the odometers accumulate. Translation adds $\lvert t \rvert / S$, rotation adds the frame's axis-angle plus any projection half-angle swing, and the far odometer adds render distance deltas in voxel units. Only endpoint poses enter each frame's charge, so frames skipped by the on-demand mode are covered automatically.

### 7. The arm, and why it's padded

The rotation bound depends on $\lvert x - c \rvert$, which raises two problems. The proof covers a region, not a point, and the camera keeps moving after the proof is made.

The circumradius solves the first problem, since for a region $B$ with center $b$ and circumradius $\rho_B$ (half the diagonal), every $x \in B$ satisfies $\lvert x - c \rvert \le \lvert b - c \rvert + \rho_B$. A single voxel cell has $\rho_B = \sqrt{3}/2$ voxels, and a $4 \times 4 \times 4$ bucket has $\rho_B = 2\sqrt{3}$ voxels. The circumradius also covers the drift of the projection radius itself. The support function is Lipschitz with constant $\rho_B$, meaning $\lvert r(n') - r(n) \rvert \le \rho_B \lvert n' - n \rvert$, so a rotating normal can't change the box's projection radius faster than the arm charge already accounts for. The soundness theorem below doesn't need that as a separate step, since bounding the sweep at every point of $B$ controls the center distance and the radius together, but it helps to see that the same constant covers both views.

The second problem needs padding, because translation can carry the camera away from the region while the proof is alive, lengthening the true arm. The proof is only ever trusted while its total charge stays at or under its clearance $s$, though, and the translation odometer is part of that charge at full weight, so any moment the proof is trusted satisfies $\Delta T \le s$. Padding the stored arm by the clearance itself therefore covers every reachable case. The stored arm is

$$a \;=\; \lvert b - c_0 \rvert + \rho_B + s,$$

where $c_0$ is the camera position at proof time and $s$ is the clearance being stored, already shaved and capped by the float defenses of section 10.

That arm buys the soundness theorem. For a proof trusted at a later moment with odometer deltas $\Delta T$ (translation), $\Delta R$ (rotation), and $\Delta F$ (render distance), the trust check is

$$\Delta T + \Delta F + a\,\Delta R \;\le\; s,$$

and we must show the verdict still holds, meaning the true plane sweep relative to every point of $B$ is under the true clearance. All terms are non-negative, so trusting implies $\Delta T \le s$. The true sweep for any $x \in B$ is bounded by the per-frame charges of section 6,

$$\text{sweep}(x) \;\le\; \Delta T + \Delta F + \big(\lvert b - c_0 \rvert + \rho_B + \Delta T\big)\Delta R \;\le\; \Delta T + \Delta F + \big(\lvert b - c_0 \rvert + \rho_B + s\big)\Delta R \;=\; \Delta T + \Delta F + a\,\Delta R \;\le\; s,$$

and $s$ was an understatement of the verdict's true clearance to begin with (section 5, plus the shave in section 10). So the verdict holds. Note the inner step used $\Delta T \le s$, which the trust check itself guarantees, so the bound is self-consistent rather than circular. The pad uses the already-shaved, already-capped clearance, so it can't feed back into itself.

### 8. Expiries, or validity in one comparison

Storing $s$, $a$, and the proof-time odometer readings would make every validity check reconstruct the deltas. Instead each proof is stored as an expiry, a precomputed odometer reading past which it's dead. Define the proof's charge function over the running totals $T$, $R$, $F$,

$$m \;=\; (T + F) + R \cdot a.$$

At proof time this evaluates to $m_0$, and the stored expiry is $E = m_0 + s$. Then at any later time,

$$m \le E \iff (\Delta T + \Delta F) + \Delta R \cdot a \le s,$$

which is exactly the trust condition of section 7. The odometers only grow, so $m$ only grows, and an expired proof stays expired. Checking a proof is one multiply, one add, and one compare.

Each voxel's proof packs into one `Vector3`. X holds the visible expiry, Y holds the culled expiry, Z holds the arm. A proof carries one verdict at a time, so the other expiry slot holds the sentinel $-1$, and since $m \ge 0$ always, the sentinel can never validate. The comparison is inclusive ($m \le E$) so a zero-clearance proof still counts while the camera is perfectly still, where $m$ hasn't moved either.

One simplification hides in that charge. Section 5 keeps the side-plane and far-plane clearances separate, but a voxel proof has no field left for two of them, so it stores their minimum, and the base term $T + F$ charges render distance change at the same full weight as translation. The render distance can't move the side planes at all, so for them the $F$ charge is a pure overcharge, and an overcharge only ever expires the proof early. Bucket verdicts have the room to keep the split, and section 9 shows what it buys them.

For a worked example, take a voxel 950 studs out at default scale, so its center is 9.5 voxels from the camera and its arm base is $9.5 + 0.87 \approx 10.4$. The frustum test proves it visible with 4.2 voxels of slack, which shaves to 4.19, giving arm $a \approx 14.6$. Say the odometers read $T + F = 100$ and $R = 2$ at proof time, so $m_0 = 100 + 2 \times 14.6 = 129.2$ and the stored expiry is $133.4$. Over the next frames the camera travels 220 studs (2.2 voxels) and turns 0.09 radians. Now $m = 102.2 + 2.09 \times 14.6 = 132.7 \le 133.4$, still trusted, no frustum test needed. One more 0.06 radian turn pushes $m$ to $133.6$ and the proof expires, and the next time the search meets this voxel it runs a fresh test.

### 9. Bucket verdicts and the side/far split

Bucket verdicts live in plain table fields with no packing pressure, so a single verdict can afford two expiries, one governed by the side planes and one by the far plane. That's the split a voxel proof gives up, since its two expiry slots are spent on the visible and culled verdicts instead. The bucket charge omits the far odometer from the base, $m = T + R \cdot a$, and the trust check is two comparisons,

$$m \le E_{side} \quad\text{and}\quad m + F \le E_{far},$$

which lets each plane family charge only the motion that can actually move it. The side planes are pinned to the camera and ignore the render distance entirely, so $F$ stays out of the side check. The far plane moves under translation, rotation, and render distance change, so the far check includes all three.

A fully inside bucket stores both expiries from its two clearances, $E_{side} = m_0 + s_{side}$ and $E_{far} = m_0 + F_0 + s_{far}$. Since the render distance controller breathes every frame (section 18), keeping $s_{far}$ separate is what stops that breathing from draining the side clearance too.

A culled bucket was rejected by exactly one plane, and which plane decides the shape of the record. If the far plane rejected it, only the far plane coming back can overturn the verdict, and every motion source that moves the far plane is charged in the far check, so $E_{far} = m_0 + F_0 + s$ and $E_{side} = \infty$. If a side plane rejected it, the bucket is outside at any render distance, so far-plane breathing is irrelevant, $E_{side} = m_0 + s$ and $E_{far} = \infty$.

The arm follows section 7 with the bucket's circumradius and the governing clearance as the pad,

$$a \;=\; \lvert b - c_0 \rvert + 2\sqrt{3} + s_{pad},$$

where $s_{pad}$ is the rejection margin for a culled bucket and $\min(s_{side}, s_{far})$ for an inside one. The pad choice is sound by the same argument as before. Whichever checks must pass for the verdict to be trusted, each bounds $\Delta T$ by its own clearance, so $\Delta T \le s_{pad}$ in every trusted state. Bucket clearances skip the voxel proofs' cap because there's no packing precision to protect (the fields are full doubles), and a longer-lived verdict at the bucket layer is pure win.

### 10. Float error, the shave, the flush limits, and the cap

Every analytic inequality so far is one-sided in the safe direction. The sphere radius overestimates the projection radius, margins subtract $\varepsilon$, the small-angle and triangle inequalities overcharge motion, the circumradius and the translation pad overstate the arm, and subset regions inherit understated clearances (section 11). None of those can make a proof outlive its verdict. The one error source that cuts both ways is floating point rounding, and it gets a dedicated budget.

Voxel proofs pack into `Vector3` components, which are 32-bit floats. Storing an expiry rounds it by at most one part in $2^{23} \approx 1.2 \times 10^{-7}$, and the arm's own rounding feeds the charge the same way, so the comparison $m \le E$ can be off by roughly $1.2 \times 10^{-7}$ of the compared magnitude. The defense is `SLACK_SAFETY`, which shaves 0.01 voxels off every clearance on its way into storage, so rounding would have to reach a hundredth of a voxel before a proof could outlive its verdict.

That budget is what sets the odometer flush limits. The caches flush and re-anchor at zero when $T + F$ passes 16384 voxels or $R$ passes 64 radians, so the compared magnitude stays under $16384 + 64a$, and the rounding error stays under

$$1.2 \times 10^{-7} \times (16384 + 64a) < 0.01 \quad\text{for}\quad a < 1000 \text{ voxels},$$

which at default scale means arms out past 100,000 studs, far beyond any reachable render distance. The combined translation and render distance limit amounts to over 1.6 million studs of accumulated motion, and the rotation limit is about ten full revolutions, minutes of ordinary mouselook or seconds of deliberate spinning. In ordinary play flushes are infrequent, and each one costs a single cold frame. The flush always clears the caches and the odometers together, because re-anchoring the odometers alone would shrink $m$ and resurrect every expired proof.

`SLACK_CAP` bounds each voxel proof's stored clearance at 8 voxels, rejection margins included. That bounds the arm pad (section 7), and with it both the magnitude entering the f32 expiry and how stale any single proof is allowed to grow before motion forces a re-check. The cap costs nothing in the common case, since a proof with 8 voxels of allowance already survives most of a scene's moment-to-moment motion.

### 11. Stamping proofs through the search tree

The search touches the proof cache at five sites. The proof walk trusts still-valid proofs inside a volume, a resolved single voxel stores a fresh proof, a volume proven fully outside stamps culled proofs across its slice, a volume proven fully inside stamps visible ones, and the budget fallback rereads old proofs when time runs out. The first four each need a small soundness argument, and the fifth bends the chain on purpose.

Trusting is sound by construction wherever it happens, in the proof walk or at a single voxel. A proof is only honored when its expiry check passed this frame and every voxel found expired or missing moves on to a fresh test rather than being assumed either way.

A single voxel that gets frustum-tested stores a visible slack of

$$s \;=\; \min(\text{own inside slack},\ \text{inherited slack},\ \text{exit clearance}),$$

one term per plane category. Planes the cell was tested against and found inside contribute the measured slack. Planes masked off by ancestors contribute the inherited slack, which is valid because an ancestor box fully inside a plane contains the cell, so the cell is at least as far inside, and every test in one frame shares the same odometer baseline, so the numbers compare like for like. Straddled planes contribute their exit clearance, since the intersect verdict survives until some plane sweeps entirely past the cell, and that's exactly what exit clearance measures (section 5). The culled case is simpler, since the stored margin is just the rejecting plane's margin and no other plane matters.

When a whole volume proves fully outside, every voxel in its slice is stamped culled with the volume's rejection margin. Each voxel is a subset of the volume's box, so its minimum signed distance to the rejecting plane is at least the box's, and the margin transfers. Fully inside volumes stamp the box's slack (already min-ed with the inherited slack) onto every voxel the same way. In both cases the rotation arm is computed per voxel at that voxel's own distance, not the box's, so big volumes don't smear one arm across cells at very different ranges.

The plane mask that children inherit is sound for the same subset reason. A plane the parent box is entirely inside of can neither reject nor straddle anything contained in the box, so skipping it loses nothing, and the slack it would have contributed travels along as the inherited slack instead.

Occlusion-contested buckets add one more inherited-slack source. A bucket fully inside the frustum whose box merely straddles an umbra seeds a volume with every frustum plane masked off, so proofs stamped inside it lean entirely on the inherited slack. For a freshly classified bucket that slack is this frame's measured clearance, covered by the same-frame argument above. For a bucket riding a cached verdict it's the verdict's remaining expiry margin, $E - m$ per plane family with the side and far margins min-ed together. That's sound because the stored expiry understates the proof-time clearance and the accumulated charge overstates the plane sweep since then, so

$$E - m \;=\; s - (m - m_0) \;\le\; s - \text{sweep} \;\le\; \text{the clearance that remains right now},$$

and it's read against the same odometer baseline every stamp in the frame shares, so the numbers compare like for like.

The splitting machinery preserves all of this exactly. A volume splits at an integer coordinate, and a voxel key $k$ goes to the low child precisely when $k < split$, which for integers means $k + 1 \le split$, so the whole cell $[k, k+1)$ lies inside the low child's box, and likewise for the high child. Buckets partition the voxels, root slices partition the seed buffer, and in-place partitioning keeps child slices disjoint and tiling, so every occupied voxel in the query box is resolved exactly once per frame, with no dedup pass needed.

The budget fallback is the one place the chain bends. When time runs out, the voxels in unreached volumes are re-marked visible if their last proof carried a visible verdict, valid or not, which can go wrong in two ways. A stale visible voxel stays visible a little longer (inclusion, harmless), and a voxel whose verdict would have flipped to visible this frame stays hidden (a real miss). The miss is bounded in time rather than hoped away. The skipped count feeds the render distance controller, which shrinks the workload until the search fits its budget again. The fairness rotation cycles a different root volume to the top of the stack each frame, so every straddling region periodically gets the front of the budget. Culled-stamped voxels overwrite any old visible expiry, so the fallback can't resurrect a voxel that was last proven culled.

Above the whole tree sits the whole-frame replay (SYSTEM.md section 7), whose soundness needs no geometry at all. The pass is a deterministic function of its inputs, namely the frustum planes (themselves a pure function of the camera pose, the projection, the render distance, and the voxel size), the occupied voxel key set, the built umbra planes, the occluder cap, and the proof caches. The replay gate demands each of those be bit-identical to the last complete pass, witnessed by the motion accumulators and the flush count (any pose, projection, or render distance change charges one of them, and a camera swap or voxel size change flushes), the grid's occupancy generation, the umbra build count with both occlusion generations, and the cap by value. A deterministic function of identical inputs can only reproduce its output, so handing back the recorded output is exact rather than approximate. The cache state stays consistent through a replay streak too. Replayed frames write no stamps, and with the odometers frozen no proof ages and nothing invalidates, so when the gate finally breaks, the resuming pass sees the caches exactly as the anchor pass left them, a state an ordinary next frame could have seen anyway. Two exclusions close the argument. A truncated pass never anchors, since its output leaned on the stale-verdict fallback rather than the inputs alone, and proofs written by frames before the anchor need no extra watching, because everything that can falsify one (motion, flushes, voxel removals, occluder generations) already sits in the gate's list.

### 12. Umbra volumes, and why inside means hidden

Occlusion culling (SYSTEM.md section 8) rests on one geometric claim. For a solid box occluder $O$ and camera position $c$ outside it, the umbra is the set of points $q$ whose sightline segment $[c, q]$ passes through $O$, and the claim is that the constructed plane set captures a subset of that umbra exactly, so anything fully inside every plane is hidden.

The construction works in the occluder's local frame, where $O$ is an axis-aligned box with half-extents $h$. A face is camera-facing when the camera's local coordinate on that face's axis exceeds the half-extent (strictly, so a grazing camera errs toward fewer camera-facing faces). Between one and three faces are camera-facing for any outside camera. The plane set is then

1. one cap plane per camera-facing face, the face's own plane with its outward normal, so the hidden side is behind the face, and
2. one silhouette plane per edge shared by a camera-facing face and a non-camera-facing face, passing through $c$ and that edge, oriented so the adjacent camera-facing face's center is strictly on the hidden side.

Any $q$ strictly inside all of those planes is occluded. The camera is strictly in front of every camera-facing face's plane (that's the classification), and $q$ is behind every one of them (those are the caps), so the segment $[c, q]$ crosses each such plane exactly once. Let $F^{*}$ be the camera-facing face whose plane the segment crosses last, at the point $x^{*}$. We show $x^{*}$ lands within $F^{*}$'s rectangle, which puts it on the box's surface and the segment through the box.

The rectangle is bounded by its four edges, and each edge is one of two kinds. If the edge is shared with another camera-facing face $G$, the segment crossed $G$'s plane at or before $x^{*}$ (that crossing wasn't the last one), and past its crossing the segment is behind $G$'s plane, so $x^{*}$ is behind it, which bounds $x^{*}$ on that edge's side because $G$'s plane cuts $F^{*}$'s plane exactly along their shared edge. If instead the edge is shared with a non-camera-facing face, it's a silhouette edge and carries a constructed plane through $c$. The camera sits on that plane and $q$ is strictly inside it, so every point of the segment, $x^{*}$ included, is inside it by convexity. That plane also meets $F^{*}$'s plane exactly along the edge itself (both contain the edge, and $c$ is strictly off $F^{*}$'s plane, so the two planes are distinct), and the orientation rule anchored the face center to the inside, so within $F^{*}$'s plane the inside half is precisely the rectangle's side of the edge. Either way $x^{*}$ is bounded onto the rectangle's side of all four edges, so $x^{*} \in F^{*}$, the segment meets the box, and $q$ is hidden.

Notice the proof never needed the face classification to match the exact geometry at the boundaries. It only needed camera-strictly-in-front of each classified camera-facing face (guaranteed by the strict comparison) and the two incidence facts about the constructed planes. A borderline camera that classifies a barely-visible face as back-facing builds a different, still sound plane set. The remaining degenerate cases are dodged rather than argued: an occluder is skipped outright when the camera is inside the (eroded) box, when the camera is nearly collinear with a silhouette edge (the plane's normal is numerically unstable), or when an orienting face center sits on its silhouette plane. Skipping an occluder only loses culling.

The umbra's defining property also makes occluder selection prunable. Every umbra point $q$ has its segment $[c, q]$ passing through the occluder at some $y$, with $q$ farther along the ray than $y$. Against a plane through the camera (a frustum side plane, or the extra plane the selection adds facing straight backwards), the signed distance along that ray is linear and zero at $c$, so $y$ strictly outside forces $q$ outside too. Against the far plane the camera is strictly inside, the ray crosses the plane at most once going outward, and $q$ sits past $y$, so $y$ outside again forces $q$ outside. Either way, an occluder fully outside any one of those planes casts an umbra fully outside the same plane, where no frustum-visible voxel can be, so dropping it before scoring loses nothing. The backwards-facing plane is what catches a box straddling the region directly behind the camera, which the side planes can't individually reject because they all meet at the camera. The test runs on the occluder's world-aligned bounding box, which contains the oriented box, so the enlargement can only keep a useless occluder, never drop a useful one, and a kept useless occluder merely competes for a selection slot.

The box-versus-umbra test is the section 5 machinery with the planes swapped, the same sphere prefilter, the same projection radius, the same $\varepsilon$ guard. The semantics invert: fully inside every plane means occluded (and the verdict requires strict clearance beyond $\varepsilon$, so float noise errs visible), fully outside any plane means this umbra can never touch the box or anything within it (its mask bit is pruned for the box's children), and a straddle proves nothing on its own, so the search splits the box and re-tests the pieces, with a single cell that still straddles staying visible. With up to `maxOccluders` umbrae live at once, a box is hidden when any single umbra fully contains it. There is no fusion of partial coverage across occluders, which only under-culls.

Two representation choices speed the test up without touching its semantics. Each plane is stored as a unit normal and a precomputed scalar offset (the dot of a point on the plane with the normal), so a signed distance is one dot product and one subtraction rather than a point subtraction and a dot. And the caps are laid out ahead of the silhouette planes, because the prune path breaks on the first fully-outside plane it finds, and for the most common non-occluded box, one sitting between the camera and the occluder or off past it, the world-fixed cap is the plane that rejects.

Before any plane runs, a per-umbra world AABB gives a six-comparison gate. The umbra is unbounded, so the AABB covers only the part of it the search can ever test, everything within $R'$ of the camera, where $R'$ is the farthest any point of a testable box can sit (the frustum's own AABB expanded by one coarse bucket, measured from the camera). Soundness comes from a scaling argument. Any umbra point within $R'$ is $c + \lambda(k - c)$ for some $k$ in the eroded box and $1 \le \lambda \le R'/d_{min}$, where $d_{min}$ is the camera's distance to the eroded box, since $\lambda \lvert k - c \rvert \le R'$ and $\lvert k - c \rvert \ge d_{min}$. Scaling about $c$ by the fixed factor $\Lambda = R'/d_{min}$ is linear, so with $k$ a convex combination of the eroded corners, both $k$ and its scaled image are convex combinations of the corners and their scaled images, and every such umbra point lies in the convex hull of the eight corners and their eight $\Lambda$-scaled images. The AABB of those sixteen points therefore contains every umbra point the search can encounter, and a box that misses the AABB is clear of that umbra. One caveat matters for section 13: the gate measures no plane margin, so a verdict that wants durability against camera motion has to go back to the planes for it.

### 13. Occlusion allowances: the pad, the pivot bound, and the clear side

Occlusion between the camera and a fixed world region depends only on the camera's position, so a cached occlusion proof charges only the translation odometer, and the question is how much translation a verdict survives. Two independent arguments each yield a sound allowance, and a proof stores the larger. The first is uniform, built into the construction, and capped by the occluder's thinnest dimension. The second scales with how deep the tested box sits inside the umbra, which is what keeps proofs alive behind thin walls, where the first is nearly worthless.

The uniform allowance comes from the erosion pad. The umbra planes are not built from $O$ itself but from $O$ eroded inward by a pad $w$, the box with half-extents $h - w$, where

$$w = \min\left(\tfrac{1}{2}\min(h_x, h_y, h_z),\ S\right)$$

so every eroded extent stays positive and the pad never exceeds one voxel. Section 12's proof then says a box fully inside the eroded umbra (a coarse bucket, a search volume, or a single cell, the argument never uses the box's size) has every sightline $[c_0, q]$ passing through the eroded box, and that is the durability we need.

Take any camera position $c$ with $\lvert c - c_0 \rvert \le w$ and any $q$ in the box. The original segment contains a point $y \in \mathrm{erode}(O, w)$ at some parameter $t$, meaning $y = (1 - t)c_0 + tq$. The moved segment $[c, q]$ contains the point $y' = (1 - t)c + tq = y + (1 - t)(c - c_0)$, and $\lvert y' - y \rvert \le \lvert c - c_0 \rvert \le w$. Every point within $w$ of the eroded box lies in $O$, by the definition of erosion, so $y' \in O$ and the moved sightline is still blocked. The verdict survives any translation up to $w$, from any direction, with no lever arms and no angles. The cost of the pad is a slightly smaller umbra every frame, and its weakness is that $w$ never exceeds half the occluder's thinnest half-extent, so a thin wall grants only a few studs of allowance no matter how deep in its shadow the box sits.

The depth-scaled allowance asks a different question: for which moved cameras $c$ does the section 12 plane set built at $c$ still contain the box? Wherever it does, section 12's proof applied at $c$ hides the box outright, with no reference to $c_0$. Note this is a statement about the mathematical plane set at $c$, not about what a rebuild at $c$ would produce, so the build-time degeneracy skips play no role here. That plane set relates to the one measured at proof time through three facts.

First, the plane set at $c$ has the same shape while no face flips its camera-facing classification. Classification on axis $a$ compares the camera's local coordinate $\hat{c}_a$ against the eroded half-extent $h'_a$, and a world translation of magnitude $t$ moves each local coordinate by at most $t$ (the local frame is orthonormal). So the classification is stable while $t$ stays under the topology margin

$$\tau = \min_a \big\lvert\, \lvert \hat{c}_a \rvert - h'_a \,\big\rvert,$$

which also keeps the camera outside the eroded box, since falling inside would flip every visible face hidden. Same classification means the same cap planes and one silhouette plane per the same edge lines.

Second, the box stays inside every cap plane for free. Caps are face planes of the eroded box, fixed in the world, identical in both plane sets, and the box was measured strictly inside them at proof time.

Third, each silhouette plane pivots about its fixed edge line, and the pivot is exactly boundable. Let $\Pi$ be the plane through $c_0$ and edge line $L$, and $\Pi'$ the plane through $c$ and the same line, with $\alpha \in [0, \pi/2]$ the angle between them. Both planes contain $L$, so everything reduces to the 2D cross-section orthogonal to $L$, where the planes are two lines through one point and $c_0$ projects to a point at distance $\rho = d(c_0, L)$ from it. Since $c_0$ lies on $\Pi$, its distance to $\Pi'$ is exactly $\rho \sin\alpha$, and that distance is at most $\lvert c - c_0 \rvert \le t$ because $c$ lies on $\Pi'$. So $\sin\alpha \le t / \rho$, with no approximation.

Now take any point $q$ at distance $m$ from $\Pi$ and distance $d = d(q, L)$ from the edge line (so $d \ge m$). In the cross-section, $q$'s offset from the pivot splits into $m$ perpendicular to $\Pi$ and $\sqrt{d^2 - m^2}$ along it, so its distance to the rotated plane is at least $m\cos\alpha - \sqrt{d^2 - m^2}\,\sin\alpha$, which stays positive exactly when $\tan\alpha < m / \sqrt{d^2 - m^2}$, that is, when $\sin\alpha < m / d$. And because that lower bound is monotone in $\alpha$, the sign of $q$'s side never flips at any intermediate rotation either, so $q$ stays strictly on the same side of the plane throughout. Combining with the pivot bound, any point with margin $m$ keeps its side of a silhouette plane whenever

$$t \le m \cdot \frac{\rho}{d(q, L)}.$$

Side preservation has to hold for two points per plane, and their conditions differ only in which margins and distances go in. The box's own points all carry the box's measured silhouette margin. And each plane's orienting face center must also keep its side, because section 12's proof identifies the hidden half-space as the face center's side, so if the face center crossed the plane the box would be inside the wrong half. The face center's margin is the $\lvert side \rvert$ distance the orientation step already computes, and its distance to the edge line is exactly the eroded half-extent of the in-face axis perpendicular to the edge. Both are known at build time, so each umbra stores one shape margin

$$\sigma = \min\left(\tau,\ \min_i \lvert side_i \rvert \cdot \frac{\rho_i}{d(F_i, L_i)}\right)$$

covering the classification and every plane's orientation at once. One nuance needs pinning down: if the moved camera lands collinear with an edge line, the plane through $c$ and $L$ is not unique, but any choice works, including $\Pi$ itself, and the bounds above hold for all of them.

The box side substitutes conservative bounds for each quantity. The margin $m_{min}$ is the minimum over silhouette planes measured against the box's support, so every point of the box is at least that deep, and on the sphere prefilter path the sphere radius overstates the projection radius, so the margin only ever understates. The distance $d(q, L)$ is bounded through the pivot's foot, $d(q, L) \le \lvert q - c_0 \rvert + \rho \le D_{max} + \rho$, where $D_{max}$ is the box center's distance plus its circumradius. And $\rho / (D_{max} + \rho)$ grows with $\rho$, so substituting $\rho_{min}$, the minimum camera-to-edge-line distance over the umbra's silhouette edges (free at build time, since the construction already computes each edge's cross product), is sound for every plane at once. Altogether the pivot allowance is

$$t_{pivot} = \min\left(\sigma,\ m_{min} \cdot \frac{\rho_{min}}{D_{max} + \rho_{min}}\right)$$

and the stored allowance is $\max(w/S, t_{pivot})$ voxels, each term shaved by the 0.01 voxel `SLACK_SAFETY` to absorb f32 packing error. For scale, take the test fixture: a $400 \times 400 \times 40$ wall 200 studs from the camera with $S = 100$, and a one-voxel box four voxels out along the axis. The pad grants $0.09$ voxels. The pivot bound measures $m_{min} \approx 1.96$, $\rho_{min} \approx 2.69$, $D_{max} \approx 4.87$, and grants about $0.69$ voxels, over seven times the pad, growing further with depth. Rotation, FOV changes, and render distance changes still charge nothing, which is what makes occlusion proofs the most durable in the system, and for a stationary camera they never expire at all.

The same machinery runs in reverse to cache verdicts on the clear side, and there are two of them, differing in what they claim about the boxes inside. The strong form is the clear verdict, that a box is outside every umbra built this frame. A box fully outside one plane of an umbra can never be touched by it. If the pruning plane is a cap, the plane is world-fixed and stays in the plane set while the shape margin holds, so the prune survives $\sigma$ outright. If it is a silhouette plane with outside margin $m$, the pivot lemma is symmetric (side preservation never asked which side), so the prune survives $\min(\sigma, m \cdot \rho_{min} / (D_{max} + \rho_{min}))$. The outside margin is measured against the box's support, so every contained box is outside by at least as much, which means a clear verdict inherits downward: one measurement covers every voxel the box holds. A box that prunes every umbra can therefore store the minimum of its per-umbra bounds as a clear proof's translation allowance, but the bounds have to come from planes, and the fast test prunes through the section 12 AABB gate whenever it can, which measures nothing. So the allowance is measured in a second, ungated pass over every umbra's planes, run only after the fast test already pruned everything. Coarse buckets earn one at seeding, and a search volume whose own test prunes its last umbra earns one for its slice, stamped onto every voxel it covers, one measuring pass amortized across the whole slice and the proof's whole lifetime. An umbra the box is outside of without being fully outside any single plane (possible near the corners of the umbra's reach, where only the whole intersection excludes the box) yields no measurable margin, so the stamp is suppressed, costing durability and never soundness.

Single voxels get the weak form, the not-occluded verdict, that this cell is not fully inside any umbra. Cells are where the strong form goes quiet: the cells that need a durable answer hug umbra boundaries, where a whole-box outside margin is zero by definition because the box straddles. The witness is one point rather than a whole box. Take any plane of an umbra and the box's maximum signed distance against it, $p = dist + r$ with $r$ the exact projection radius (never the sphere overestimate, since overstating $p$ here would overstate durability). If $p$ is strictly positive, the support point realizing it sits strictly outside that plane, and no test can call the box fully inside that umbra while the point keeps its side. The witness point is a fixed world point, so the pivot lemma applies to it verbatim: a cap witness survives $\sigma$ (the plane is world-fixed and the point never moves), and a silhouette witness survives $\min(\sigma, p \cdot \rho_{min} / (D_{max} + \rho_{min}))$, with the same foot-triangle and minimum-edge-distance substitutions as the hidden side. Each umbra contributes its best witness across its planes (any one suffices, so the maximum is sound), the caps are scanned first because a cap witness already achieves the $\sigma$ ceiling and ends that umbra's scan, and the cell stores the minimum across umbrae, since the claim quantifies over all of them. What the weak form gives up is inheritance. A box can poke out of an umbra while a cell inside it sits fully hidden, so the verdict is meaningless for anything with contents, and only leaf cells, which have none, carry it. It's measured right after the leaf test concludes not occluded, against every built umbra rather than just the caller's mask (an umbra an ancestor volume pruned was pruned without a measured margin, so the cell's stamp re-derives its own), and at a still camera the stamp is written even when the shaved allowance lands at zero, because expiries compare inclusively and a perfectly still camera keeps a zero-allowance verdict alive without re-testing, matching the frustum proofs' zero-clearance semantics. Under camera motion the stamp gate described below decides whether the write happens at all.

A hidden verdict is witnessed by a single occluder, so it stores the occluder generation, a counter bumped whenever any registered occluder moves, resizes, or unregisters, and a mismatch kills the proof in one comparison. Adding an occluder doesn't bump it, since more occlusion can't falsify a hidden verdict, and neither does per-frame selection churn, since a proof anchored to an unchanged occluder stays true whether or not that occluder was selected. The clear-side verdicts are a different kind of claim. Both forms quantify over every umbra built that frame, and the two events the occluder generation deliberately ignores, a new occluder arriving and the top-K selection admitting a different member, are exactly the events that could falsify them. So both carry the clear generation, bumped whenever the occluder generation bumps and additionally whenever this frame's built selection contains an occluder that last frame's didn't. A selection that only shrinks doesn't bump it, because removing an umbra can't put a box inside one. The over-invalidation direction is the safe one: a spurious bump merely re-earns clear-side verdicts, while a missed bump could trust a stale one, and the entrant rule guarantees that never happens, so cached verdicts always match what a fresh test against this frame's umbrae would say.

Both counters pack into an f32 proof component, exact only up to $2^{24}$, so each wraps to zero and flushes the occlusion proofs before reaching that bound. The proofs live in the visibility cache in voxel units, so every event that flushes the cache (camera swap, voxel resize, odometer re-anchor) drops them too. Like the bucket verdicts, bucket occlusion proofs are proven against the bucket's full unclipped box, so they stay true as the query bounds move with the camera.

The umbra set itself is allowed to outlive its frame, and the pad lemma above is the whole justification. The planes built at $c_0$ describe the eroded box's shadow from $c_0$, and for any camera $c$ with $\lvert c - c_0 \rvert \le w$ the moved-sightline argument makes every point inside them hidden from $c$ too, so the built plane set keeps issuing sound hidden verdicts while the translation odometer has advanced less than the tightest built pad since the build. What changes is the bookkeeping. Every bound in this section ($w$, $\sigma$, the pivot substitutions, $D_{max}$ measured from the anchor) limits total camera motion from the build position, while a stored proof charges the odometer from its own stamp reading, so an allowance granted on a reuse frame is debited by the drift already spent. A proof stamped at drift $t_d$ with geometric bound $B$ stores $B - t_d$, making its expiry exactly the anchor reading plus $B$, and the odometer is path length, an overestimate of displacement, so the camera stays within $B$ of the anchor while the proof lives. A debit that lands at or below zero grants nothing, costing durability and never soundness. Reuse yields to any event that could invalidate the geometry rather than the arithmetic. An occluder generation bump means the geometry moved. A selection that would build a different top set means a new umbra no reused measurement covered, and the clear generation has to see it, so selection is re-scored every frame and only construction is skipped. A visibility cache flush re-anchors the odometer, making drift since the build unmeasurable (and possibly hiding a camera swap), so a flush counter forces the rebuild. And the pad crossing itself rebuilds. The umbra AABBs and the $c_0$-anchored distances stay at their build values during reuse, and both stalenesses only prune more or grant less, erring visible.

Separately from soundness, stamps are gated by worth. The motion floor for a frame is the translation the last processed frame added to the odometer, and a stamp whose shaved allowance falls below it will already be expired by the time anything reads it, since proofs are only consulted on later frames. So stamp writers skip proofs under the floor, the measuring passes return zero as soon as any umbra's $\sigma$ ceiling or measured witness can't reach the floor plus the debit and the shave, and a whole frame's measuring is ruled out up front when even the tightest built $\sigma$ falls short. None of this changes a single verdict, because stamps only relocate work across frames: a cell without a proof re-tests, which is exactly what a cell with an expired proof does. At a perfectly still camera the floor is zero, expiries compare inclusively, and every stamp is written and trusted, zero-allowance ones included, so the gate vanishes. The floor is measured motion rather than a tuned speed threshold, so the gate adapts to any camera and any scene, engaging exactly when proofs would die younger than one frame.

The proofs stamp at two granularities with one encoding, per coarse bucket during seeding and per voxel below that. A record's X holds the hidden expiry and Z the clear-side expiry, with $-1$ marking the verdict the record doesn't carry, and Y holds the generation matching the verdict it does. Bucket records carry hidden or clear, and voxel records carry hidden or not occluded, written cell by cell at the leaf or slice at a time when a volume proves itself fully occluded or fully clear. A trusted hidden proof skips the bucket or cell outright. A trusted clear proof lets the search treat the bucket as if no umbra existed, taking the pure frustum path, and a trusted not-occluded proof does the same for one cell in the proof walk, letting its frustum proof settle it alone. In every case that is exactly what a fresh test would have concluded. Every error direction in this section is either expiring early or showing more, never culling something visible.

## Part III: The supporting algorithms

### 14. Which voxels an object occupies

An object's bounding box has half-extents $h$, and its radius is the box's circumradius $r = \lvert h \rvert$, so the whole object fits in a ball of radius $r$ about its center. The single-voxel rule keeps an object in just its center's voxel while $r \le S/4$. The worst case puts the center right against a voxel face, where the object can overhang into the neighbor by at most $r \le S/4$, a quarter voxel. That's the precise content of the claim in SYSTEM.md that the threshold and the overhang bound are the same number.

A larger object fills every voxel its oriented box actually overlaps, and the fill is a separating-axis test pruned to the axes that matter. The exact box-versus-box SAT uses fifteen axes, the three world axes, the box's three face axes, and nine edge-edge cross products. The fill gets the first three for free, drops the last nine deliberately, and tests the middle three exactly.

The world axes come free from the candidate range. The oriented box's projection onto world axis $i$ has half-length $w_i = \sum_j \lvert R_{ij} \rvert h_j$ (the support function again, in matrix form), so the box's world AABB is $position \pm w$. Candidate voxels are those whose keys lie in $\lfloor (position - w)/S \rfloor$ through $\lfloor (position + w)/S \rfloor$. Floor arithmetic shows any candidate's interval $[kS, (k+1)S)$ overlaps the AABB's interval on every world axis, and overlapping on an axis is exactly the statement that the axis doesn't separate. So no candidate can be separated along a world axis, and testing them would be wasted work.

The face axes are tested exactly. Let $u_j$ be the box's $j$-th axis (column $j$ of its rotation matrix) and $l_j = (v - position) \cdot u_j$ the voxel center's coordinate along it. A voxel cube projects onto $u_j$ with radius $\frac{S}{2}(\lvert u_{jx} \rvert + \lvert u_{jy} \rvert + \lvert u_{jz} \rvert)$, so the separation threshold is

$$reach_j \;=\; h_j + \tfrac{S}{2}\big(\lvert u_{jx} \rvert + \lvert u_{jy} \rvert + \lvert u_{jz} \rvert\big),$$

and the voxel survives axis $j$ when $\lvert l_j \rvert \le reach_j$. Dropping the nine cross axes can only ever over-include. SAT says the shapes are disjoint when any axis separates, so ignoring some axes just means a few disjoint voxels slip through, and they're confined to thin corner slivers where only an edge-edge axis would have caught the separation. An extra voxel costs a little bookkeeping, while a wrongly excluded one could hide an object from the search, so the pruning errs the only acceptable way.

The inner loop exploits linearity to fill rows in one shot. Down a row of voxels along world Z, each coordinate steps by a constant, $l_j(t) = l_j(0) + t \cdot S\,u_{jz}$, so each $\lvert l_j \rvert \le reach_j$ constraint is one interval of $t$, and the row's surviving run is the intersection of three intervals clipped to the row, computed with two multiplications per axis against the step's precomputed reciprocal instead of a test per voxel. The surviving region is the intersection of three slabs, which is convex, so its meeting with a line really is a single contiguous run, and rounding that run to integers carries a $10^{-6}$ outward bias so a center sitting exactly on a slab boundary stays in the run instead of being lost to float noise. An axis nearly perpendicular to world Z steps by essentially zero, so its coordinate is constant down the row and the constraint either passes the whole row or empties it, handled as a flat accept-or-reject rather than dividing by a near-zero step.

The whole computation assumes finite geometry, so a non-finite center or radius is rejected before any of it runs. A NaN cannot index a voxel at all and would feed a NaN into the maintenance queue's priority, where it corrupts the heap order, and an infinite extent gives the candidate range infinite bounds that the fill loop could never step across, hanging the frame. The recompute leaves such an object in whatever voxels it already holds and reslots it once its geometry is finite again.

### 15. Sorting visible voxels with a counting sort

Ingest wants the visible voxels closest-first so its budget is spent nearest the camera. The distance used is Manhattan distance in voxel coordinates,

$$d_1 = \lvert \Delta x \rvert + \lvert \Delta y \rvert + \lvert \Delta z \rvert,$$

used as an ordering heuristic rather than a measurement. It surrounds the true Euclidean distance within fixed bounds, $d_2 \le d_1 \le \sqrt{3}\,d_2$, so it can locally swap voxels at similar range but never puts the far side of the map ahead of the near side, and it costs three absolute values with no square root. The voxel maintenance queue orders its work by the same metric measured in studs, since a rough closest-first order is all it needs there too.

These distances are small non-negative integers, at most three times the render distance in voxels, which makes a counting sort the right tool. One pass computes each voxel's distance and the maximum. One pass tallies how many voxels sit at each distance. A prefix sum turns the tallies into each distance's starting output slot. A final pass scatters every voxel directly into its slot, walking the input in order so equal-distance voxels keep their relative order (the sort is stable). Total work is $O(n + d_{max})$ with no comparisons and no element shuffling, versus $O(n \log n)$ for a comparison sort, and both the keys' integrality and their bounded range are load-bearing in that claim.

### 16. The per-object cull during ingest

Voxel visibility is conservative, so ingest re-checks each object individually before scoring it. The render distance check compares the object's center distance against the render distance directly, which is the definition of "within render distance" at the object level. It's phrased as a failure of $distance \le renderDistance$ so that a NaN distance (from a NaN position upstream) falls into the cull instead of feeding a NaN priority into the update queue, where it would silently corrupt the band arithmetic and the ordering.

The frustum check tests the object's bounding sphere against the four side planes using the closed-form normals from section 3. With $v$ the camera-to-object vector and $forward = v \cdot \hat{F}$, $right = v \cdot \hat{R}$, $up = v \cdot \hat{U}$, the signed distance from the center to the right plane is $right\cos\theta_h - forward\sin\theta_h$ and to the left plane is $-right\cos\theta_h - forward\sin\theta_h$. The larger of the two is

$$\lvert right \rvert \cos\theta_h - forward \sin\theta_h,$$

so a single expression tests both planes of the pair, and the object is culled when it exceeds the bounding radius on either the horizontal or the vertical pair, sphere fully outside a plane meaning fully outside the frustum. The check only runs when the center is in front of the camera plane. Centers behind it are kept without testing, and skipping a cull is always safe. Such objects are rare in practice anyway, since they can only reach ingest through a voxel the search already called visible.

### 17. Screen size and the priority bands

The scoring currency is screen size. At distance $D$, the viewport's half-height spans $D\tan\theta_v$ studs of world space, so an object of bounding radius $r$ covers

$$screenSize = \frac{r}{\max(D, 10^{-4})}\cdot\frac{1}{\tan\theta_v}$$

of the half-screen as a fraction. A screenSize of 1 means the object's radius alone spans half the screen height. The clamp on $D$ exists because an object centered on the camera would otherwise divide by zero, and an object that close fills the view and sorts first regardless.

Each object's refresh clock is read with a per-object jitter offset, drawn once at add time uniformly from $\pm 2$ milliseconds. A thousand objects spawned the same frame would otherwise cross the refresh thresholds in lockstep forever, arriving as a thundering herd every few frames. A fixed phase offset per object breaks the lockstep without adding per-frame randomness.

The queue dequeues lower bands ahead of higher ones, and every band is assigned at scoring time by the branch that produced it. The first three regions from SYSTEM.md section 9 compute a numeric score first. Writing $j$ for the jittered elapsed time since the object's last update, $best$ and $worst$ for the refresh periods, and $u = (j - best)/(worst - best)$ for progress through the refresh window,

| Region | Condition | Score | Resulting range |
| --- | --- | --- | --- |
| p0 | $j \ge worst$ | $0.9 - screenSize$ | below $0.9$, unboundedly negative for huge objects |
| Very nearby | $D < 30$ studs | $D / 30$ | $[0, 1)$ |
| Scored | otherwise | $85(1 - \min(screenSize, 1)) + 13(1 - u) + 2D/renderDistance$ | roughly $(0, 100]$ |

The conditions overlap only at the very nearby region, and the refresh clock wins both ways. An object still inside its best refresh period parks in the over-refreshed tier even while hugging the camera, and one past its worst period takes the p0 score rather than the nearby one.

The band layout carves 219 bands into back-to-back regions. Scores under the p0 threshold of $0.9$ take 18 equal slices of width $0.05$, with a hugely negative score from a screen-filling object clamping into the front band and a score of exactly $0.9$ from a zero screen size clamping into the last slice, so an overdue object never leaks out of the p0 region. Scores in $[0.9, 100]$ take one band per whole point, about a hundredth of the scored scale. The fast pass takes one band per voxel in search order with the tiers capped at 89, and the over-refresh region takes the last ten bands, sliced by screen size as $\lfloor 10(1 - \min(screenSize, 1)) \rfloor$ clamped to its own top band. The last two regions never form a numeric score at all. The fast pass hands every object in the $k$-th visible voxel its region's $k$-th band directly (the dump begins at the voxel after the one that exhausted the budget, so the lowest tier that actually occurs is the second), and voxels from the cap on share the deepest tier, trading relative order among the farthest voxels for a bounded band table.

The hard separations are structural. Every fair band precedes every fast band, and every fast band precedes every over-refresh band, by construction of the region offsets, so coarsely dumped objects never jump properly scored ones, and even the deepest dumped voxel sorts ahead of every object that was refreshed within its best period, which is the guarantee that fast-passed objects can still update this frame. The scored regions deliberately interleave at their edges. A nearby object closer than 27 studs scores under the p0 threshold and so picks up p0 treatment from the update loop, which is intended, things touching the camera deserve it, and a scored object whose blend dips under the threshold takes the matching p0 slice the same way.

In the scored band, the screen size term is clamped at 1 so a screen-filling object can't push its score negative and impersonate a p0, the refresh term decays linearly from 13 to 0 as the object ages through its window (so urgency rises as the value falls), and the distance term adds at most 2 as a tiebreak among similar screen sizes. The weights sum to 100 and encode the judgment that what's biggest on screen matters most, fairness across objects matters some, and raw proximity is a nudge. As a worked example, take a 12-stud-radius object 400 studs out under the default 70 degree vertical field of view, where the section 3 formulas give $\tan\theta_v = \tan(35^\circ) \approx 0.70$ at any aspect ratio, so $screenSize \approx 0.043$. If it last updated 50 ms ago with the default 16.7 to 66.7 ms window, $u \approx 0.67$, and at the default render distance midpoint of 1075 studs its score is roughly $81.4 + 4.3 + 0.7 \approx 86.4$, a low-urgency object that still beats anything fast-passed.

The banding realizes the scored ordering at band granularity rather than exactly. It is monotonic in the score wherever a score exists, so two objects can dequeue out of score order only when their scores land in the same band, which bounds any inversion by one slice width. Among p0s that means $0.05$ of screen size, in the scored range one point (a hundredth of the scale), among fast-pass tiers nothing at all (the bands are the tiers), and among over-refreshed objects $0.1$ of screen size at the back of the queue where order barely matters. Ties within a band drain in staged order, which is closest-voxel-first.

The update loop's budget arithmetic closes the loop. The band layout makes the p0 region a strict prefix of the drain, and inside that prefix the iterator allows $1.15\times$ the update budget (0.46 ms on the 0.4 ms default), with `strictlyEnforceWorstRefreshRate` raising the p0 allowance to a full second, which against frame timescales means unbounded. The first object past the prefix is checked against the plain budget immediately. Between checks the iterator yields without reading the clock. Each check plans the next one to cover about half the remaining budget at the average per-object pace measured so far, capped at eight objects, so the added overrun beyond a per-object check is about half of whatever budget remained at the previous check and the plan collapses to per-object checks as the budget nears. The dt handed to your callback is the real elapsed time since that object's last update. Each update stamps the object with the clock reading captured when that frame's iteration began, and dt is the difference between this frame's reading and the stamp, so every object in a frame ages against the same instant. Dts of a second or more are excluded from the average-refresh metric since they measure an object coming back into view, not the system's pace.

### 18. The render distance controller

The controller turns three measurements into one decision per frame. Each load is normalized so 1 means exactly at budget, then weighted by how costly an overrun of that kind is,

$$load = \max\left(1.3\,\frac{searchDuration}{searchBudget},\ \ 1.0\,\frac{ingestDuration}{ingestBudget},\ \ 0.8\,\frac{averageObjectDt}{refreshMidpoint}\right).$$

The third term measures update pace, the average per-object dt against the midpoint of the configured refresh range, so it reads as "are objects refreshing about as often as the configuration promises". The weights mean search trips the overload threshold at about 77 percent of its raw budget ($1/1.3$), while the refresh pace has to run 25 percent past the midpoint to do the same. A zero budget means that pass is configured off rather than starved, so it gets no vote. Search and ingest durations would divide into an infinite load, and a switched-off update pass has no pace worth reading. A fresh instance seeds the average dt at the best refresh period, which reads as full headroom and lets the controller grow from its starting midpoint until real measurements take over.

The direction rule has a deadband instead of a single cutoff. The distance shrinks when $load > 1$ or when any of the last four frames hit a search or ingest fallback (the search and ingest skip counts from the last four frames sit in small ring buffers, and a nonzero average over one is exactly "some frame in the window skipped"). It grows only when $load < 0.6$ and the window is clean, and between the thresholds it holds. That deadband is what prevents dithering around a single magic number, and the four-frame memory makes one bad frame apply pressure briefly instead of being forgotten the next frame.

The step size adapts multiplicatively. A move that doesn't reverse the previous one multiplies the step by 1.2, and any hold or reversal multiplies it by 0.35, clamped between 0.02 percent and 2.5 percent of the configured range's midpoint (the working step starts at 3 percent and clamps down on its first move). Both of the behaviors the controller needs fall out of those exponents. A scene change that demands a different distance produces a sustained direction, and the step grows from floor to cap in $\log(125)/\log(1.2) \approx 27$ frames, accelerating the catch-up. Around equilibrium the direction alternates or holds, and each such frame multiplies the step by 0.35, collapsing it from cap to floor in about 5 frames, so the distance parks instead of oscillating. The applied move is $direction \times step \times midpoint$, clamped into the configured range, and a zero-width range never reaches any of this because the controller exits before voting.

### 19. The error-direction ledger

Every approximation in the system, and which way it leans.

| Approximation | Direction | Why it's safe |
| --- | --- | --- |
| Sphere prefilter in the box test | Understates margins and slacks | Verdicts unchanged, proofs just expire sooner |
| The $\varepsilon$ guard band | Inclusion at verdict time, subtracted from stored clearances | Misjudgment capped at $10^{-4}$ voxels, with no durability granted |
| Five-plane intersect test near frustum corners | Inclusion | Extra voxels cost work, and ingest re-culls per object |
| Small-angle and triangle inequalities in motion charges | Overcharges the odometers | Proofs expire early, never late |
| Circumradius and translation pad in the arm | Overstates the arm | The rotation debit is an overestimate in every trusted state |
| Slack shave (0.01 voxels) and flush limits | Expires proofs early | The flush limits are sized so rounding stays under the shave |
| Slack cap (8 voxels) | Expires proofs early | Bounds arm inflation and staleness |
| Skipping the nine cross axes in the voxel fill | Inclusion | Disjoint corner-sliver voxels get tracked, none get lost |
| Single-voxel rule for small objects | Bounded overhang | At most a quarter voxel, by the threshold's own definition |
| Manhattan distance orderings | Local reordering only | Within $\sqrt{3}$ of Euclidean, used purely as a heuristic order |
| Center-based render distance cull | Definitional | "Within render distance" is measured at the object's center |
| Keeping center-behind objects in the ingest cull | Inclusion | Skipping a cull is always safe |
| Pivot-bound substitutions (support margins, sphere-path margins, the foot triangle for $d(q, L)$, the minimum edge distance) | Understates the allowance | Occlusion proofs expire early, never late |
| Umbra AABB gate | Exact for testable boxes, grants no durability | The scaled-corner hull contains every umbra point within reach of the search, and gate prunes stamp nothing |
| Clear-generation selection rule | Over-invalidates | Any selection entrant flushes the clear-side proofs, even ones it couldn't falsify, so a trusted proof always matches a fresh test |
| Not-occluded witness at leaf cells (one support point outside one plane) | Weakest sound claim, understated durability | No test can call the cell occluded while the witness keeps its side, and the expiry errs early |
| Volume-slice clear stamps measure the volume's box | Understates each cell's allowance | Every contained cell is outside by at least the box's margin, so the shared expiry only ever comes early |
| Fast-pass voxel-tier bands | Coarsens ordering only | Still ahead of over-refreshed work, still updates this frame |
| Banded dequeue order in the update queue | Coarsens ordering only | Inversions bounded by one queue band (a hundredth of the scored scale), the hard separations are region offsets so they hold exactly, and ties drain closest-first |
| Planned update-drain clock checks | Bounded budget overrun | Each check plans the next at half the remaining budget and the plan collapses to per-object checks near the cutoff, so the added overrun is about half of what remained |
| Due-bucket exit sweep | Exits fire up to one bucket period (a thirtieth of a second) late | The grace period is smoothing rather than exact timing, deadlines are re-read when a bucket opens so nothing fires early, and entries are never dropped |
| Search budget fallback | Stale verdicts, possible bounded misses | Metered, pressures the render distance down, kept fair by the fairness rotation |
| Umbra strict-inside requirement with the $\varepsilon$ guard | Visible bias | A box straddling an umbra boundary is never called occluded |
| Erosion pad on the occluder | Shrinks the umbra | Under-culls, and the pad is exactly what backs the proofs' translation allowance |
| Degenerate umbra skips (camera inside, edge collinear, coplanar face center) | No umbra at all | Skipping an occluder only loses culling |
| Occluder prefilter on the world-aligned bounding box | Keeps borderline occluders | A dropped occluder's umbra misses the frustum, and the enlarged box only ever keeps more |
| Occlusion granularity floor (leaf cells straddling an umbra stay visible, budget-fallback voxels untested) | Inclusion | Hidden voxels can slip into the frame, never the reverse |
| Voxel occlusion proofs consulted only in umbra-contested volumes | Inclusion | Cells behind a deselected occluder re-earn visible until it wins a slot again, and the bucket proofs (honored regardless of selection) confine the leak to straddled buckets |
| Occlusion generation bumps and cache flushes | Expire proofs early | A changed, removed, or wrapped-past occluder can never back a live proof |
| Umbra reuse within the pad (stale plane sets, AABBs, and anchor while drift stays under the tightest built pad) | Visible bias, debited durability | The pad lemma blocks every reused sightline for cameras within the pad, every allowance hands out its bound minus the drift already spent, and the stale AABBs and anchor only prune more |
| Stamp gate at the motion floor (skipped stamps, bailed measuring passes) | Relocates work, never verdicts | A skipped stamp behaves exactly like an expired one, and a still camera's floor is zero so nothing is skipped |
| Whole-frame search replay | None, exact | The gate demands bit-identical inputs and a complete anchor pass, and a deterministic pass over identical inputs can only reproduce its output |

Read down the direction column and the thesis of section 1 reappears. Outside the explicitly metered search fallback, every shortcut either shows slightly too much or re-checks slightly too soon. Nothing in the pipeline has a path to silently hiding a visible object, and that's the sense in which CullThrottle is correct.
