# The Math Behind CullThrottle

[SYSTEM.md](./SYSTEM.md) explains what CullThrottle does each frame and why each mechanism exists. This document is the companion that shows the work: the exact formulas, where they come from, and the arguments for why they're sound. Read SYSTEM.md first, since this document leans on its vocabulary (voxels, buckets, search volumes, proofs, the motion odometers) and mostly doesn't redefine it. The one refinement is the word slack. SYSTEM.md uses it for every number that rides along with a verdict, but the math here needs to tell those numbers apart, so clearance becomes the umbrella term, slack means the clearance of an inside verdict, margin means the clearance of an outside one, and exit clearance belongs to straddles. Section 5 makes all three precise.

## 1. What "correct" means here

CullThrottle approximates constantly, so correctness can't mean exactness. The claim this document defends is narrower and more useful. Every approximation errs in a known direction, and the directions are chosen so the system never hides something it should show.

1. A voxel or bucket reported culled is provably outside the view frustum, up to float tolerances that are themselves padded against (section 10).
2. A voxel reported visible may actually sit slightly outside the view. Over-inclusion costs a little wasted work, never a visual bug, and is accepted everywhere.
3. A cached verdict may expire sooner than the math strictly requires, never later.
4. The one deliberate exception is the search's budget fallback, which reuses stale verdicts when time runs out. It's metered, fed to the render distance controller, and spread across regions by the fairness rotation. Section 11 pins down exactly what it can get wrong.

Throughout, $S$ is the voxel size in studs (100 by default), $c$ is the camera position, and a plane is a pair $(p, n)$ of a point on the plane and a unit outward normal. The signed distance from a point $x$ to a plane is

$$f(x) = (x - p) \cdot n$$

with the convention that normals point out of the frustum, so positive distance means outside.

## Part I: The geometry

### 2. Voxel coordinates

An object whose position is $p$ lives in the voxel with integer key $k = \lfloor p / S \rfloor$, taken componentwise. That voxel covers the world-space cube $[kS, (k+1)S)$ per axis, which in voxel coordinates (world coordinates divided by $S$) is simply $[k, k+1)$. Every box the search tests is one of these half-open integer boxes or a union of them, with ordered bounds ($x_0 \le x_1$ and so on).

The frustum planes are built once per frame directly in voxel coordinates by dividing the plane positions by $S$ and leaving the normals alone. That works because signed distance scales uniformly:

$$\left(\tfrac{x}{S} - \tfrac{p}{S}\right) \cdot n = \frac{(x - p) \cdot n}{S}.$$

Signs are preserved, so every verdict is unchanged, and every clearance comes out in voxel units, which is exactly the unit the motion odometers charge in. Normals are unit length before and after because uniform scaling doesn't rotate directions.

### 3. Building the five frustum planes

The camera reports `MaxAxisFieldOfView`, the full field of view across the larger viewport axis. With viewport aspect ratio $a$ (width over height), the vertical and horizontal half-angles $\theta_v$ and $\theta_h$ satisfy

$$\tan\theta_v = \frac{\tan(\mathrm{FOV}_{max}/2)}{\max(a, 1)}, \qquad \tan\theta_h = a \tan\theta_v.$$

The first formula reads off which axis the camera is reporting. On a tall viewport the max axis already is vertical, so $\theta_v$ is $\mathrm{FOV}_{max}/2$ directly. On a wide viewport ($a > 1$) the max axis is horizontal, so $\mathrm{FOV}_{max}/2$ is really $\theta_h$, and dividing its tangent by $a$ recovers the vertical half-angle through the standard projection relation $\tan\theta_h = a\tan\theta_v$. At render distance $d$, the far plane is the rectangle of half-height $H = d\tan\theta_v$ and half-width $W = aH$, centered $d$ studs down the look vector.

Each side plane contains the camera position and one edge of that far rectangle, so its normal is the cross product of the camera's up vector (for left and right) or right vector (for top and bottom) with the edge-to-camera direction, normalized and oriented outward. Writing $\hat{R}, \hat{U}, \hat{F}$ for the camera's right, up, and look vectors, the resulting normals have a clean closed form in the camera basis:

$$n_{right} = \hat{R}\cos\theta_h - \hat{F}\sin\theta_h, \qquad n_{left} = -\hat{R}\cos\theta_h - \hat{F}\sin\theta_h,$$

$$n_{top} = \hat{U}\cos\theta_v - \hat{F}\sin\theta_v, \qquad n_{bottom} = -\hat{U}\cos\theta_v - \hat{F}\sin\theta_v.$$

You can sanity-check the orientation with a probe point straight ahead. For $x = c + D\hat{F}$, the distance to the right plane is $D\hat{F} \cdot n_{right} = -D\sin\theta_h < 0$, correctly inside. These closed forms come back twice more, once for projection changes (section 6) and once for the per-object cull (section 14). The fifth plane is the far plane, passing through the far rectangle's center with normal $\hat{F}$, so points beyond the render distance get positive (outside) distance.

The frustum with no near plane is the pyramid from the camera apex to the far rectangle, which is the convex hull of five points, the apex and the four far corners. The axis-aligned bounding box of a convex hull is the componentwise min and max of its generating points, so the search's frustum AABB is computed from exactly those five points, floored into voxel indices (with one added to the max side to form the half-open query box).

### 4. Why there is no near plane

The four side planes all pass through the camera position, and that makes a near plane redundant. Here is the proof. Take any point at position $c - a\hat{F} + b\hat{R} + e\hat{U}$ with $a > 0$, meaning strictly behind the camera. Its signed distances to the right and left planes are

$$f_{right} = b\cos\theta_h + a\sin\theta_h, \qquad f_{left} = -b\cos\theta_h + a\sin\theta_h,$$

which sum to $2a\sin\theta_h$. Since the field of view is under 180 degrees, $\sin\theta_h > 0$, so the sum is strictly positive and at least one of the two distances is positive. Every point behind the camera is therefore already outside the left or right plane (or both), and a near-plane test would reject nothing new.

### 5. The box test

`Frustum.isBoxInFrustum` classifies a voxel-space box against the planes. Write the box as center $m$ and half-extents $e = (e_x, e_y, e_z)$. For one plane, let $d = (m - p) \cdot n$ be the center's signed distance.

The exact tool is the box's projection radius onto the plane normal,

$$r = e_x \lvert n_x \rvert + e_y \lvert n_y \rvert + e_z \lvert n_z \rvert.$$

This is the support function of the box in direction $n$. Each coordinate of a box point ranges over $[m_i - e_i,\ m_i + e_i]$ independently, so the maximum of $(x - m)\cdot n$ over the box is reached by picking each coordinate at the extreme matching the sign of $n_i$, which gives exactly $r$, and the minimum is $-r$ by symmetry. So the box's signed distances to the plane fill the interval $[d - r,\ d + r]$. Everything below follows from looking at that interval.

Before computing $r$, the test tries the circumscribing sphere, whose radius is $\rho = \lvert e \rvert$. Writing $r = e \cdot (\lvert n_x \rvert, \lvert n_y \rvert, \lvert n_z \rvert)$ and applying Cauchy-Schwarz with $\lvert n \rvert = 1$ gives $r \le \rho$, so sphere verdicts are valid box verdicts and the cheap check can settle the clear cases. With a guard band $\varepsilon = 10^{-4}$ voxels, the per-plane outcomes are these.

1. If $d > \rho + \varepsilon$ (sphere shortcut) or $d > r + \varepsilon$ (exact), the box is entirely outside this plane, hence outside the frustum. The reported rejection margin is $d - \rho - \varepsilon$ or $d - r - \varepsilon$, both understatements of the true clearance $d - r$, which is the safe direction for a stored proof.
2. If $d \le -\rho$ (sphere shortcut) or $d + r \le \varepsilon$ (exact), the box is entirely inside this plane. The slack is $-d - \rho$ or $-(d + r)$, again at most the true distance-to-touching, and again safe. In the exact case the box may actually poke up to $\varepsilon$ past the plane while being called fully inside. That misjudgment is at most $10^{-4}$ voxels (a hundredth of a stud at default scale), it errs toward calling things visible, and the slack it stores is then negative and clamps to zero, so the generous verdict gets no durability.
3. Otherwise the box straddles the plane. The plane's bit is set in the returned straddle mask, and the test records the exit clearance $r + \varepsilon - d$, how much $d$ would have to grow before case 1 could fire. Until that much motion accumulates, the box provably still has a foot inside this plane.

The box intersects the frustum when no tested plane lands in case 1. The slack reported alongside an intersect verdict is the minimum of the case 2 slacks, kept separately for the side planes and the far plane because a render distance change moves only the far plane (voxel proofs merge the two in section 8, while bucket verdicts keep them apart in section 9). A box hugging the frustum's exterior near an edge or corner can pass the conservative "Not fully outside any single plane" frustum test while being outside the true frustum. The error direction is inclusion, the cost is a few falsely visible voxels near the silhouette, and the per-object cull during ingest (section 14) catches most of what slips through.

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

and across multiple frames the per-frame charges add up by the triangle inequality, which is exactly what the odometers accumulate. Translation adds $\lvert t \rvert / S$, rotation adds the frame's axis-angle plus any projection half-angle swing, and the far odometer adds render distance deltas in voxel units. Only endpoint poses enter each frame's charge, so frames skipped by the on-demand mode are covered automatically.

### 7. The arm, and why it's padded

The rotation bound depends on $\lvert x - c \rvert$, which raises two problems. The proof covers a region, not a point, and the camera keeps moving after the proof is made.

The circumradius solves the first problem, since for a region $B$ with center $b$ and circumradius $\rho_B$ (half the diagonal), every $x \in B$ satisfies $\lvert x - c \rvert \le \lvert b - c \rvert + \rho_B$. A single voxel cell has $\rho_B = \sqrt{3}/2$ voxels, and a $4 \times 4 \times 4$ bucket has $\rho_B = 2\sqrt{3}$ voxels. The circumradius also covers the drift of the projection radius itself. The support function is Lipschitz with constant $\rho_B$, meaning $\lvert r(n') - r(n) \rvert \le \rho_B \lvert n' - n \rvert$, so a rotating normal can't change the box's projection radius faster than the arm charge already accounts for. The soundness theorem below doesn't need that as a separate step, since bounding the sweep at every point of $B$ controls the center distance and the radius together, but it helps to see that the same constant covers both views.

The second problem needs padding, because translation can carry the camera away from the region while the proof is alive, lengthening the true arm. The proof is only ever trusted while its total charge stays at or under its clearance $s$, though, and the translation odometer is part of that charge at full weight, so any moment the proof is trusted satisfies $\Delta T \le s$. Padding the stored arm by the clearance itself therefore covers every reachable case. The stored arm is

$$a \;=\; \lvert b - c_0 \rvert + \rho_B + s,$$

where $c_0$ is the camera position at proof time and $s$ is the clearance being stored, already shaved and capped by the float defenses of section 10.

Here is the soundness theorem this buys, for a proof trusted at a later moment with odometer deltas $\Delta T$ (translation), $\Delta R$ (rotation), and $\Delta F$ (render distance). The trust check is

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

A worked example makes the lifecycle concrete. A voxel sits 950 studs out at default scale, so its center is 9.5 voxels from the camera and its arm base is $9.5 + 0.87 \approx 10.4$. The frustum test proves it visible with 4.2 voxels of slack, which shaves to 4.19, giving arm $a \approx 14.6$. Say the odometers read $T + F = 100$ and $R = 2$ at proof time, so $m_0 = 100 + 2 \times 14.6 = 129.2$ and the stored expiry is $133.4$. Over the next frames the camera travels 220 studs (2.2 voxels) and turns 0.09 radians. Now $m = 102.2 + 2.09 \times 14.6 = 132.7 \le 133.4$, still trusted, no frustum test needed. One more 0.06 radian turn pushes $m$ to $133.6$ and the proof expires, and the next time the search meets this voxel it runs a fresh test.

### 9. Bucket verdicts and the side/far split

Bucket verdicts live in plain table fields with no packing pressure, so a single verdict can afford two expiries, one governed by the side planes and one by the far plane. That's exactly the split a voxel proof gives up, since its two expiry slots are spent on the visible and culled verdicts instead. The bucket charge omits the far odometer from the base, $m = T + R \cdot a$, and the trust check is two comparisons,

$$m \le E_{side} \quad\text{and}\quad m + F \le E_{far},$$

which lets each plane family charge only the motion that can actually move it. The side planes are pinned to the camera and ignore the render distance entirely, so $F$ stays out of the side check. The far plane moves under translation, rotation, and render distance change, so the far check includes all three.

A fully inside bucket stores both expiries from its two clearances, $E_{side} = m_0 + s_{side}$ and $E_{far} = m_0 + F_0 + s_{far}$. Since the render distance controller breathes every frame (section 16), keeping $s_{far}$ separate is what stops that breathing from draining the side clearance too.

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

Trusting is sound by construction wherever it happens, in the proof walk or at a single voxel. A proof is only honored when its expiry check passed this frame, which is exactly the guarantee section 7 established, and every voxel found expired or missing moves on to a fresh test rather than being assumed either way.

A single voxel that gets frustum-tested stores a visible slack of

$$s \;=\; \min(\text{own inside slack},\ \text{inherited slack},\ \text{exit clearance}),$$

one term per plane category. Planes the cell was tested against and found inside contribute the measured slack. Planes masked off by ancestors contribute the inherited slack, which is valid because an ancestor box fully inside a plane contains the cell, so the cell is at least as far inside, and every test in one frame shares the same odometer baseline, so the numbers compare like for like. Straddled planes contribute their exit clearance, since the intersect verdict survives until some plane sweeps entirely past the cell, and that's exactly what exit clearance measures (section 5). The culled case is simpler, since the stored margin is just the rejecting plane's margin and no other plane matters.

When a whole volume proves fully outside, every voxel in its slice is stamped culled with the volume's rejection margin. Each voxel is a subset of the volume's box, so its minimum signed distance to the rejecting plane is at least the box's, and the margin transfers. Fully inside volumes stamp the box's slack (already min-ed with the inherited slack) onto every voxel the same way. In both cases the rotation arm is computed per voxel at that voxel's own distance, not the box's, so big volumes don't smear one arm across cells at very different ranges.

The plane mask that children inherit is sound for the same subset reason. A plane the parent box is entirely inside of can neither reject nor straddle anything contained in the box, so skipping it loses nothing, and the slack it would have contributed travels along as the inherited slack instead.

The splitting machinery preserves all of this exactly. A volume splits at an integer coordinate, and a voxel key $k$ goes to the low child precisely when $k < split$, which for integers means $k + 1 \le split$, so the whole cell $[k, k+1)$ lies inside the low child's box, and likewise for the high child. Buckets partition the voxels, root slices partition the seed buffer, and in-place partitioning keeps child slices disjoint and tiling, so every occupied voxel in the query box is resolved exactly once per frame, with no dedup pass needed.

The budget fallback is the one place the chain bends. When time runs out, the voxels in unreached volumes are re-marked visible if their last proof carried a visible verdict, valid or not, which can go wrong in two ways. A stale visible voxel stays visible a little longer (inclusion, harmless), and a voxel whose verdict would have flipped to visible this frame stays hidden (a real miss). The miss is bounded in time rather than hoped away. The skipped count feeds the render distance controller, which shrinks the workload until the search fits its budget again. The fairness rotation cycles a different root volume to the top of the stack each frame, so every straddling region periodically gets the front of the budget. Culled-stamped voxels overwrite any old visible expiry, so the fallback can't resurrect a voxel that was last proven culled.

## Part III: The supporting algorithms

### 12. Which voxels an object occupies

An object's bounding box has half-extents $h$, and its radius is the box's circumradius $r = \lvert h \rvert$, so the whole object fits in a ball of radius $r$ about its center. The single-voxel rule keeps an object in just its center's voxel while $r \le S/4$. The worst case puts the center right against a voxel face, where the object can overhang into the neighbor by at most $r \le S/4$, a quarter voxel. That's the precise content of the claim in SYSTEM.md that the threshold and the overhang bound are the same number.

A larger object fills every voxel its oriented box actually overlaps, and the fill is a separating-axis test pruned to the axes that matter. The exact box-versus-box SAT uses fifteen axes, the three world axes, the box's three face axes, and nine edge-edge cross products. The fill gets the first three for free, drops the last nine deliberately, and tests the middle three exactly.

The world axes come free from the candidate range. The oriented box's projection onto world axis $i$ has half-length $w_i = \sum_j \lvert R_{ij} \rvert h_j$ (the support function again, in matrix form), so the box's world AABB is $position \pm w$. Candidate voxels are those whose keys lie in $\lfloor (position - w)/S \rfloor$ through $\lfloor (position + w)/S \rfloor$. Floor arithmetic shows any candidate's interval $[kS, (k+1)S)$ overlaps the AABB's interval on every world axis, and overlapping on an axis is exactly the statement that the axis doesn't separate. So no candidate can be separated along a world axis, and testing them would be wasted work.

The face axes are tested exactly. Let $u_j$ be the box's $j$-th axis (column $j$ of its rotation matrix) and $l_j = (v - position) \cdot u_j$ the voxel center's coordinate along it. A voxel cube projects onto $u_j$ with radius $\frac{S}{2}(\lvert u_{jx} \rvert + \lvert u_{jy} \rvert + \lvert u_{jz} \rvert)$, so the separation threshold is

$$reach_j \;=\; h_j + \tfrac{S}{2}\big(\lvert u_{jx} \rvert + \lvert u_{jy} \rvert + \lvert u_{jz} \rvert\big),$$

and the voxel survives axis $j$ when $\lvert l_j \rvert \le reach_j$. Dropping the nine cross axes can only ever over-include. SAT says the shapes are disjoint when any axis separates, so ignoring some axes just means a few disjoint voxels slip through, and they're confined to thin corner slivers where only an edge-edge axis would have caught the separation. An extra voxel costs a little bookkeeping, while a wrongly excluded one could hide an object from the search, so the pruning errs the only acceptable way.

The inner loop exploits linearity to fill rows in one shot. Down a row of voxels along world Z, each coordinate steps by a constant, $l_j(t) = l_j(0) + t \cdot S\,u_{jz}$, so each $\lvert l_j \rvert \le reach_j$ constraint is one interval of $t$, and the row's surviving run is the intersection of three intervals clipped to the row, computed with two multiplications per axis against the step's precomputed reciprocal instead of a test per voxel. The surviving region is the intersection of three slabs, which is convex, so its meeting with a line really is a single contiguous run, and rounding that run to integers carries a $10^{-6}$ outward bias so a center sitting exactly on a slab boundary stays in the run instead of being lost to float noise. An axis nearly perpendicular to world Z steps by essentially zero, so its coordinate is constant down the row and the constraint either passes the whole row or empties it, handled as a flat accept-or-reject rather than dividing by a near-zero step.

The whole computation assumes finite geometry, so a non-finite center or radius is rejected before any of it runs. A NaN cannot index a voxel at all and would feed a NaN into the maintenance queue's priority, where it corrupts the heap order, and an infinite extent gives the candidate range infinite bounds that the fill loop could never step across, hanging the frame. The recompute leaves such an object in whatever voxels it already holds and reslots it once its geometry is finite again.

### 13. Sorting visible voxels with a counting sort

Ingest wants the visible voxels closest-first so its budget is spent nearest the camera. The distance used is Manhattan distance in voxel coordinates,

$$d_1 = \lvert \Delta x \rvert + \lvert \Delta y \rvert + \lvert \Delta z \rvert,$$

which is an ordering heuristic, not a measurement. It surrounds the true Euclidean distance within fixed bounds, $d_2 \le d_1 \le \sqrt{3}\,d_2$, so it can locally swap voxels at similar range but never puts the far side of the map ahead of the near side, and it costs three absolute values with no square root. The voxel maintenance queue orders its work by the same metric measured in studs, since a rough closest-first order is all it needs there too.

These distances are small non-negative integers, at most three times the render distance in voxels, which makes a counting sort the right tool. One pass computes each voxel's distance and the maximum. One pass tallies how many voxels sit at each distance. A prefix sum turns the tallies into each distance's starting output slot. A final pass scatters every voxel directly into its slot, walking the input in order so equal-distance voxels keep their relative order (the sort is stable). Total work is $O(n + d_{max})$ with no comparisons and no element shuffling, versus $O(n \log n)$ for a comparison sort, and both the keys' integrality and their bounded range are load-bearing in that claim.

### 14. The per-object cull during ingest

Voxel visibility is conservative, so ingest re-checks each object individually before scoring it. The render distance check compares the object's center distance against the render distance directly, which is the definition of "within render distance" at the object level. It's phrased as a failure of $distance \le renderDistance$ so that a NaN distance (from a NaN position upstream) falls into the cull instead of feeding a NaN priority into the update queue, where it would silently corrupt the band arithmetic and the ordering.

The frustum check tests the object's bounding sphere against the four side planes using the closed-form normals from section 3. With $v$ the camera-to-object vector and $forward = v \cdot \hat{F}$, $right = v \cdot \hat{R}$, $up = v \cdot \hat{U}$, the signed distance from the center to the right plane is $right\cos\theta_h - forward\sin\theta_h$ and to the left plane is $-right\cos\theta_h - forward\sin\theta_h$. The larger of the two is

$$\lvert right \rvert \cos\theta_h - forward \sin\theta_h,$$

so a single expression tests both planes of the pair, and the object is culled when it exceeds the bounding radius on either the horizontal or the vertical pair, sphere fully outside a plane meaning fully outside the frustum. The check only runs when the center is in front of the camera plane. Centers behind it are kept without testing, and skipping a cull is always safe. Such objects are rare in practice anyway, since they can only reach ingest through a voxel the search already called visible.

### 15. Screen size and the priority bands

The scoring currency is screen size. At distance $D$, the viewport's half-height spans $D\tan\theta_v$ studs of world space, so an object of bounding radius $r$ covers

$$screenSize = \frac{r}{\max(D, 10^{-4})}\cdot\frac{1}{\tan\theta_v}$$

of the half-screen as a fraction. A screenSize of 1 means the object's radius alone spans half the screen height. The clamp on $D$ exists because an object centered on the camera would otherwise divide by zero, and an object that close fills the view and sorts first regardless.

Each object's refresh clock is read with a per-object jitter offset, drawn once at add time uniformly from $\pm 2$ milliseconds. A thousand objects spawned the same frame would otherwise cross the refresh thresholds in lockstep forever, arriving as a thundering herd every few frames. A fixed phase offset per object breaks the lockstep without adding per-frame randomness.

The queue dequeues lower bands ahead of higher ones, and every band is assigned at scoring time by the branch that produced it. The first three regions from SYSTEM.md section 8 compute a numeric score first. Writing $j$ for the jittered elapsed time since the object's last update, $best$ and $worst$ for the refresh periods, and $u = (j - best)/(worst - best)$ for progress through the refresh window,

| Region | Condition | Score | Resulting range |
| --- | --- | --- | --- |
| p0 | $j \ge worst$ | $0.9 - screenSize$ | below $0.9$, unboundedly negative for huge objects |
| Very nearby | $D < 30$ studs | $D / 30$ | $[0, 1)$ |
| Scored | otherwise | $85(1 - \min(screenSize, 1)) + 13(1 - u) + 2D/renderDistance$ | roughly $(0, 100]$ |

The conditions overlap only at the very nearby region, and the refresh clock wins both ways. An object still inside its best refresh period parks in the over-refreshed tier even while hugging the camera, and one past its worst period takes the p0 score rather than the nearby one.

The band layout carves 219 bands into back-to-back regions. Scores under the p0 threshold of $0.9$ take 18 equal slices of width $0.05$, with a hugely negative score from a screen-filling object clamping into the front band. Scores in $[0.9, 100]$ take one band per whole point, about a hundredth of the scored scale. The fast pass takes one band per voxel in search order with the tiers capped at 89, and the over-refresh region takes the last ten bands, sliced by screen size as $\lfloor 10(1 - \min(screenSize, 1)) \rfloor$ clamped to its own top band. The last two regions never form a numeric score at all. The fast pass hands every object in the $k$-th visible voxel its region's $k$-th band directly (the dump begins at the voxel after the one that exhausted the budget, so the lowest tier that actually occurs is the second), and voxels from the cap on share the deepest tier, trading relative order among the farthest voxels for a bounded band table.

The hard separations are structural. Every fair band precedes every fast band, and every fast band precedes every over-refresh band, by construction of the region offsets, so coarsely dumped objects never jump properly scored ones, and even the deepest dumped voxel sorts ahead of every object that was refreshed within its best period, which is the guarantee that fast-passed objects can still update this frame. The scored regions deliberately interleave at their edges. A nearby object closer than 27 studs scores under the p0 threshold and so picks up p0 treatment from the update loop, which is intended, things touching the camera deserve it, and a scored object whose blend dips under the threshold takes the matching p0 slice the same way.

In the scored band, the screen size term is clamped at 1 so a screen-filling object can't push its score negative and impersonate a p0, the refresh term decays linearly from 13 to 0 as the object ages through its window (so urgency rises as the value falls), and the distance term adds at most 2 as a tiebreak among similar screen sizes. The weights sum to 100 and encode the judgment that what's biggest on screen matters most, fairness across objects matters some, and raw proximity is a nudge. As a worked example, take a 12-stud-radius object 400 studs out under the default 70 degree vertical field of view, where the section 3 formulas give $\tan\theta_v = \tan(35^\circ) \approx 0.70$ at any aspect ratio, so $screenSize \approx 0.043$. If it last updated 50 ms ago with the default 16.7 to 66.7 ms window, $u \approx 0.67$, and at the default render distance midpoint of 1075 studs its score is roughly $81.4 + 4.3 + 0.7 \approx 86.4$, a fairly low-urgency object that will still comfortably beat anything fast-passed.

The banding realizes the scored ordering at band granularity rather than exactly. It is monotonic in the score wherever a score exists, so two objects can dequeue out of score order only when their scores land in the same band, which bounds any inversion by one slice width. Among p0s that means $0.05$ of screen size, in the scored range one point (a hundredth of the scale), among fast-pass tiers nothing at all (the bands are the tiers), and among over-refreshed objects $0.1$ of screen size at the back of the queue where order barely matters. Ties within a band drain in staged order, which is closest-voxel-first.

The update loop's budget arithmetic closes the loop. The band layout makes the p0 region a strict prefix of the drain, and inside that prefix the iterator allows $1.15\times$ the update budget (0.46 ms on the 0.4 ms default), with `strictlyEnforceWorstRefreshRate` raising the p0 allowance to a full second, which against frame timescales means unbounded. The first object past the prefix is checked against the plain budget immediately. Between checks the iterator yields without reading the clock. Each check plans the next one to cover about half the remaining budget at the average per-object pace measured so far, capped at eight objects, so the added overrun beyond a per-object check is about half of whatever budget remained at the previous check and the plan collapses to per-object checks as the budget nears. The dt handed to your callback is the real elapsed time since that object's last update. Each update stamps the object with the clock reading captured when that frame's iteration began, and dt is the difference between this frame's reading and the stamp, so every object in a frame ages against the same instant. Dts of a second or more are excluded from the average-refresh metric since they measure an object coming back into view, not the system's pace.

### 16. The render distance controller

The controller turns three measurements into one decision per frame. Each load is normalized so 1 means exactly at budget, then weighted by how costly an overrun of that kind is,

$$load = \max\left(1.3\,\frac{searchDuration}{searchBudget},\ \ 1.0\,\frac{ingestDuration}{ingestBudget},\ \ 0.8\,\frac{averageObjectDt}{refreshMidpoint}\right).$$

The third term measures update pace, the average per-object dt against the midpoint of the configured refresh range, so it reads as "are objects refreshing about as often as the configuration promises". The weights mean search trips the overload threshold at about 77 percent of its raw budget ($1/1.3$), while the refresh pace has to run 25 percent past the midpoint to do the same. A zero budget means that pass is configured off rather than starved, so it gets no vote. Search and ingest durations would divide into an infinite load, and a switched-off update pass has no pace worth reading. A fresh instance seeds the average dt at the best refresh period, which reads as full headroom and lets the controller grow from its starting midpoint until real measurements take over.

The direction rule has a deadband instead of a single cutoff. The distance shrinks when $load > 1$ or when any of the last four frames hit a search or ingest fallback (the search and ingest skip counts from the last four frames sit in small ring buffers, and a nonzero average over one is exactly "some frame in the window skipped"). It grows only when $load < 0.6$ and the window is clean, and between the thresholds it holds. That deadband is what prevents dithering around a single magic number, and the four-frame memory makes one bad frame apply pressure briefly instead of being forgotten the next frame.

The step size adapts multiplicatively. A move that doesn't reverse the previous one multiplies the step by 1.2, and any hold or reversal multiplies it by 0.35, clamped between 0.02 percent and 2.5 percent of the configured range's midpoint (the working step starts at 3 percent and clamps down on its first move). Both of the behaviors the controller needs fall out of those exponents. A scene change that demands a different distance produces a sustained direction, and the step grows from floor to cap in $\log(125)/\log(1.2) \approx 27$ frames, accelerating the catch-up. Around equilibrium the direction alternates or holds, and each such frame multiplies the step by 0.35, collapsing it from cap to floor in about 5 frames, so the distance parks instead of oscillating. The applied move is $direction \times step \times midpoint$, clamped into the configured range, and a zero-width range never reaches any of this because the controller exits before voting.

### 17. The error-direction ledger

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
| Fast-pass voxel-tier bands | Coarsens ordering only | Still ahead of over-refreshed work, still updates this frame |
| Banded dequeue order in the update queue | Coarsens ordering only | Inversions bounded by one queue band (a hundredth of the scored scale), the hard separations are region offsets so they hold exactly, and ties drain closest-first |
| Planned update-drain clock checks | Bounded budget overrun | Each check plans the next at half the remaining budget and the plan collapses to per-object checks near the cutoff, so the added overrun is about half of what remained |
| Due-bucket exit sweep | Exits fire up to one bucket period (a thirtieth of a second) late | The grace period is smoothing rather than exact timing, deadlines are re-read when a bucket opens so nothing fires early, and entries are never dropped |
| Search budget fallback | Stale verdicts, possible bounded misses | Metered, pressures the render distance down, kept fair by the fairness rotation |

Read down the direction column and the thesis of section 1 reappears. Outside the explicitly metered search fallback, every shortcut either shows slightly too much or re-checks slightly too soon. Nothing in the pipeline has a path to silently hiding a visible object, and that's the sense in which CullThrottle is correct.
