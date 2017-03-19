(* -------------------------------------------------------------------- *)
require import NewLogic Option Int List Real NewDistr FSet NewFMap.
require import IntExtra IntDiv RealExtra Mu_mem StdRing StdOrder StdBigop.
(*---*) import Bigint Ring.IntID RField IntOrder RealOrder BIA.
require (*--*) FinType.

pragma -oldip.
pragma +implicits.

(* -------------------------------------------------------------------- *)
(** A finite type of seeds equipped with its uniform distribution **)
clone include MFinite
rename [type] "t" as "seed"
rename "dunifin" as "dseed"
rename "duniform" as "dseed".

lemma dseed_uf_fu: is_uniform_over dseed predT.
proof.
rewrite /is_uniform_over /is_uniform dseed_fu dseed_ll /= => x y _ _.
by rewrite !dseed1E.
qed.

lemma dseed_suf: is_subuniform dseed by have [] _ [] := dseed_uf_fu.

(* -------------------------------------------------------------------- *)
(** Some output type equipped with some lossless distribution **)
type output.
op dout: { output distr | is_lossless dout } as dout_ll.

(* -------------------------------------------------------------------- *)
(** We use a PRF that, on input a seed, produces a seed and an output...*)
module type PRF = {
  proc * init() : unit
  proc f(x:seed): seed * output
}.

(** ...to build a PRG that produces random outputs... **)
(** We let our PRG have internal state, which we need to initialize **)
module type PRG = {
  proc * init(): unit
  proc prg()   : output
}.

(* -------------------------------------------------------------------- *)
(** Distinguishers can call
  *   - the PRG at most qP times, and
  *   - the PRF at most qF times, and
  *   - return a boolean *)
op qP : { int | 0 <= qP } as ge0_qP.
op qF : { int | 0 <= qF } as ge0_qF.

module type APRF = {
  proc f(x:seed): seed * output
}.

module type APRG = {
  proc prg(): output
}.

module type Adv (F:APRF,P:APRG) = {
  proc a(): bool
}.

module Exp (A:Adv,F:PRF,P:PRG) = {
  module A = A(F,P)

  proc main():bool = {
    var b: bool;

    F.init();
    P.init();
    b = A.a();
    return b;
  }
}.

(** A PRG is secure iff it is indistinguishable from sampling in $dout
    by an adversary with access to the PRF and the PRG interfaces *)
module PrgI = {
  proc init () : unit = { }

  proc prg(): output = {
    var r;

    r = $dout;
    return r;
  }
}.

(* -------------------------------------------------------------------- *)
(* Concrete considerations                                              *)

(* We use the following PRF *)
module F = {
  var m:(seed,seed * output) fmap

  proc init(): unit = {
     m <- map0;
  }

  proc f (x:seed) : seed * output = {
    var r1, r2;

    r1 <$ dseed;
    r2 <$ dout;
    if (!mem (dom m) x)
      m.[x] <- (r1,r2);

    return oget (m.[x]);
  }
}.

lemma FfL: islossless F.f.
proof. by proc; auto; rewrite dseed_ll dout_ll. qed.

(* And we are proving the security of the following PRG *)
module P (F:PRF) = {
  var seed: seed
  var logP: seed list

  proc init(): unit = {
    seed = $dseed;
  }

  proc prg(): output = {
    var r;

    (seed,r) = F.f (seed);
    return r;
  }
}.

(* -------------------------------------------------------------------- *)
(* We use the following oracle in an intermediate game that links two
   sections. Ideally, we would hide it somehwere, but nested sections
   don't work yet. *)

(* Note that it uses P's state (in which we have a useless thing) to
   avoid contaminating the final result. *)

module Psample = {
  proc init(): unit = {
    P.seed <$ dseed;
    P.logP <- [];
  }

  proc prg(): output = {
    var r1, r2;

    r1     <$ dseed;
    r2     <$ dout;
    P.logP <- P.seed :: P.logP;
    P.seed <- r1;
    return r2;
  }
}.

lemma PsampleprgL: islossless Psample.prg.
proof. by proc; auto; rewrite dseed_ll dout_ll. qed.

(* -------------------------------------------------------------------- *)
(* In preparation of the eager/lazy reasoning step                      *)

(* Again, note that none of these have their own state.  Therefore, it
   does not matter overmuch that they are not hidden. *)

module Resample = {
  proc resample() : unit = {
    var n, r;

    n = size P.logP;
    P.logP = [];
    P.seed = $dseed;
    while (size P.logP < n) {
      r = $dseed;
      P.logP = r :: P.logP;
    }
  }
}.

module Exp'(A:Adv) = {
  module A = A(F,Psample)

  proc main():bool = {
    var b : bool;
    F.init();
    Psample.init();
    b = A.a();
    Resample.resample();
    return b;
  }
}.

(* -------------------------------------------------------------------- *)
(* The Proof                                                            *)

section.
  (* Forall Adversary A that does not share memory with P or F... *)
  declare module A:Adv {P,F}.

  (* ... and whose a procedure is lossless whenever F.f and P.prg are *)
  axiom AaL (F <: APRF {A}) (P <: APRG {A}):
    islossless P.prg =>
    islossless F.f =>
    islossless A(F,P).a.

  (* We show that the adversary can distinguish P from Psample only
     when P.prg is called twice with the same input. *)

  (* First, we add some logging so we can express the bad event *)
  local module Plog = {
    proc init(): unit = {
      P.seed <$ dseed;
      P.logP <- [];
    }

    proc prg(): output = {
      var r;

      P.logP     <- P.seed :: P.logP;
      (P.seed,r) <@ F.f(P.seed);
      return r;
    }
  }.

  local lemma PlogprgL: islossless Plog.prg.
  proof. by proc; call FfL; wp. qed.

  local lemma P_Plog &m:
    Pr[Exp(A,F,P(F)).main() @ &m: res] = Pr[Exp(A,F,Plog).main() @ &m: res].
  proof.
  byequiv (_: ={glob A} ==> ={res})=> //.
  by do !sim.
  qed.

  (* Bad holds whenever:
   *  - there is a cycle in the state, OR
   *  - an adversary query collides with an internal seed. *)
  inductive Bad logP (m : ('a,'b) fmap) =
    | Cycle of (!uniq logP)
    | Collision r of (mem logP r) & (mem (dom m) r).

  lemma negBadE logP (m : ('a,'b) fmap):
    !Bad logP m <=>
      (uniq logP /\ forall r, !mem logP r \/ !mem (dom m) r).
  proof.
  rewrite -iff_negb negbK negb_and negb_forall /=.
  rewrite (@ exists_iff _ (predI (mem logP) (mem (dom m))) _).
    by move=> a /=; rewrite negb_or /predI.
  split=> [[->|r r_in_log r_in_m]|[/(Cycle _ m)|[r] @/predI [] /(Collision _ m r)]] //.
  by right; exists r.
  qed.

  (* In this game, we replace the PRF queries with fresh sampling operations *)
  inductive inv (m1 m2 : ('a,'b) fmap) (logP : 'a list) =
    | Invariant of
          (forall r, mem (dom m1) r <=> (mem (dom m2) r \/ mem logP r))
        & (forall r, mem (dom m2) r => m1.[r] = m2.[r]).

  local lemma Plog_Psample &m:
    Pr[Exp(A,F,Plog).main() @ &m: res] <=
      Pr[Exp(A,F,Psample).main() @ &m: res] +
      Pr[Exp(A,F,Psample).main() @ &m: Bad P.logP F.m].
  proof.
  apply (ler_trans (Pr[Exp(A,F,Psample).main() @ &m: res \/ Bad P.logP F.m]));
    last by rewrite Pr [mu_or]; smt w=mu_bounded.
  byequiv (_: ={glob A} ==> !(Bad P.logP F.m){2} => ={res})=> // [|/#].
  proc.
  call (_: Bad P.logP F.m, ={P.seed} /\ inv F.m{1} F.m{2} P.logP{2}).
    (* adversary is lossless *)
    by apply AaL.
    (* [Psample.prg ~ Plog.prg: I] when Bad does not hold *)
    proc; inline F.f. swap{2} 3 -2.
    auto=> /> &1 &2 _ [] m1_is_m2Ulog m2_le_m1 r1 _ r2 _.
    rewrite negBadE; case: (mem (dom F.m{1}) P.seed{2})=> [/#|//=].
    rewrite !getP /= oget_some /=.
    move=> seed_notin_m1 _; split.
      by move=> r; rewrite dom_set !inE m1_is_m2Ulog /#.
    move=> r ^/m2_le_m1; rewrite !getP=> -> r_in_m2.
    by move: (iffRL _ _ (m1_is_m2Ulog r)); rewrite r_in_m2 /#.
    (* Plog.prg is lossless when Bad holds *)
    by move=> _ _; proc; inline F.f; auto=> />; rewrite dseed_ll dout_ll.
    (* Psample.prg preserves bad *)
    move=> _ //=; proc; auto=> />; rewrite dseed_ll dout_ll /=.
    move=> &hr + v1 _ v2 _; case=> [h|r r_in_log r_in_m].
      by apply/Cycle; rewrite /= h.
    by apply/(@Collision _ _ r)=> /=; [rewrite r_in_log|rewrite r_in_m].
    (* [F.f ~ F.f: I] when Bad does not hold *)
    proc; auto=> /> &1 &2; rewrite !negBadE.
    move=> -[] uniq_log r_notin_logIm [] m_is_mUlog m2_le_m1 r1L _ r2L _.
    case: (mem (dom F.m{2}) x{2})=> [/#|//=].
    case: (mem (dom F.m{1}) x{2})=> /=.
      rewrite negBadE uniq_log=> /= /m_is_mUlog + x_notin_m2 h'; rewrite x_notin_m2 /=.
      by move: (h' x{2}); rewrite dom_set !inE.
    rewrite !getP /= => x_notin_m1 x_notin_m2 _; split.
      by move=> r; rewrite !dom_set !inE m_is_mUlog /#.
    by move=> r; rewrite !dom_set !inE !getP=> -[/m2_le_m1|] ->.
    (* F.f is lossless when Bad holds *)
    by move=> _ _; apply FfL.
    (* F.f preserves bad *)
    move=> _ //=; proc.
    case (mem (dom F.m) x).
      by rcondf 3; auto=> />; rewrite dseed_ll dout_ll.
    rcondt 3; first by do !rnd; wp.
    auto=> />; rewrite dseed_ll dout_ll //= => &hr bad_init x_notin_m v _ v0 _.
    case: bad_init=> [/(Cycle<:seed,seed * output>) -> //|r r_in_log r_in_m].
    by apply/(@Collision _ _ r)=> //=; rewrite dom_set !inE r_in_m.
  (* Returning to main *)
  call (_: ={glob F} ==> ={glob P} /\ inv F.m{1} F.m{2} P.logP{2}).
    by proc; auto=> /> &2 _ _; split.
  call (_: true ==> ={glob F}); first by sim.
  by auto=> /#.
  qed.

  local lemma Psample_PrgI &m:
    Pr[Exp(A,F,Psample).main() @ &m: res] = Pr[Exp(A,F,PrgI).main() @ &m: res].
  proof.
  byequiv (_: ={glob A} ==> ={res})=> //; proc.
  call (_: ={glob F})=> //.
    (* Psample.prg ~ PrgI.prg *)
    by proc; wp; rnd; rnd{1}; auto=> />; rewrite dseed_ll.
    (* F.f *)
    by sim.
  conseq (_: _ ==> ={glob A, glob F})=> //.
  by inline *; auto=> />; rewrite dseed_ll.
  qed.

  local lemma Resample_resampleL: islossless Resample.resample.
  proof.
  proc. while (true) (n - size P.logP);
    first by move=> z; auto; rewrite dseed_ll /#.
  by auto; rewrite dseed_ll /#.
  qed.

  local module Exp'A = Exp'(A).

  local lemma ExpPsample_Exp' &m:
      Pr[Exp(A,F,Psample).main() @ &m: Bad P.logP F.m]
    = Pr[Exp'(A).main() @ &m: Bad P.logP F.m].
  proof.
  byequiv (_: ={glob A} ==> ={P.logP, F.m})=> //; proc.
  transitivity{1} { F.init(); Psample.init(); Resample.resample(); b = Exp'A.A.a(); }
     (={glob A} ==> ={F.m, P.logP})
     (={glob A} ==> ={F.m, P.logP})=> //.
    (* Equality on A's globals *)
    by move=> &1 &2 A; exists (glob A){1}.
    (* no sampling ~ presampling *)
    sim; inline Resample.resample Psample.init F.init.
    rcondf{2} 7;
      first by move=> &hr; rnd; wp; conseq (_: _ ==> true) => //.
    by wp; rnd; wp; rnd{2} predT; auto; rewrite dseed_ll.
  (* presampling ~ postsampling *)
  seq 2 2: (={glob A, glob F, glob Plog}); first by sim.
  eager (H: Resample.resample(); ~ Resample.resample();
    : ={glob Plog} ==> ={glob Plog})
    : (={glob A, glob Plog, glob F})=> //;
    first by sim.
  eager proc H (={glob Plog, glob F})=> //.
    eager proc; inline Resample.resample.
    swap{1} 3 3. swap{2} [4..5] 2. swap{2} [6..8] 1.
    swap{1} 4 3. swap{1} 4 2. swap{2} 2 4.
    sim.
    splitwhile {2} 5 : (size P.logP < n - 1).
    conseq (_ : _ ==> ={P.logP})=> //.
    seq 3 5: (={P.logP} /\ (size P.logP = n - 1){2}).
      while (={P.logP} /\ n{2} = n{1} + 1 /\ size P.logP{1} <= n{1});
        first by auto=> /#.
      by wp; rnd{2}; auto=> />; rewrite dseed_ll; smt w=size_ge0.
    rcondt{2} 1; first by move=> &hr; auto=> /#.
    rcondf{2} 3; first by move=> &hr; auto=> /#.
    by sim.
    by sim.
    by eager proc; swap{1} 1 4; sim.
  by sim.
  qed.

  lemma P_PrgI &m:
    Pr[Exp(A,F,P(F)).main() @ &m: res] <=
      Pr[Exp(A,F,PrgI).main() @ &m: res] + Pr[Exp'(A).main() @ &m: Bad P.logP F.m].
  proof.
  by rewrite (P_Plog &m) -(ExpPsample_Exp' &m) -(Psample_PrgI &m) (Plog_Psample &m).
  qed.
end section.

(* -------------------------------------------------------------------- *)

(* We now bound Pr[Exp(A,F,Psample).main() @ &m: Bad Plog.logP F.m] *)

(* For now, we use the following counting variant of the adversary to
   epxress the final result. Everything up to now applies to
   non-counting adversaries, but we need the counting to bound the
   probability of Bad. *)

module C (A:Adv,F:APRF,P:APRG) = {
  var cF, cP:int

  module CF = {
    proc f(x): seed * output = {
      var r = witness;

      if (cF < qF) { cF = cF + 1; r = F.f(x);}
      return r;
    }
  }

  module CP = {
    proc prg (): output = {
      var r = witness;

      if (cP < qP) { cP = cP + 1; r = P.prg();}
      return r;
    }
  }

  module A = A(CF,CP)

  proc a(): bool = {
    var b:bool;

    cF = 0;
    cP = 0;
    b = A.a();
    return b;
  }
}.

lemma CFfL (A <: Adv) (F <: APRF) (P <: APRG):
  islossless F.f =>
  islossless C(A,F,P).CF.f.
proof. move=> FfL; proc; sp; if=> //. by call FfL; wp. qed.

lemma CPprgL (A <: Adv) (F <: APRF) (P <: APRG):
  islossless P.prg =>
  islossless C(A,F,P).CP.prg.
proof. move=> PprgL; proc; sp; if=> //. by call PprgL; wp. qed.

lemma CaL (A <: Adv {C}) (F <: APRF {A}) (P <: APRG {A}):
  (forall (F <: APRF {A}) (P <: APRG {A}),
    islossless P.prg => islossless F.f => islossless A(F,P).a) =>
     islossless F.f
  => islossless P.prg
  => islossless C(A,F,P).a.
proof.
move=> AaL PprgL FfL. proc.
call (AaL (<: C(A,F,P).CF) (<: C(A,F,P).CP) _ _).
  by apply (CPprgL A F P).
  by apply (CFfL A F P).
by wp.
qed.

section.
  declare module A:Adv {C,P,F}.
  axiom AaL (F <: APRF {A}) (P <: APRG {A}):
    islossless P.prg =>
    islossless F.f =>
    islossless A(F,P).a.

  lemma pr &m:
    Pr[Exp(C(A),F,P(F)).main() @ &m: res] <=
        Pr[Exp(C(A),F,PrgI).main() @ &m: res]
      + Pr[Exp'(C(A)).main() @ &m: Bad P.logP F.m].
  proof.
  apply (P_PrgI (<: C(A)) _ &m).
    move=> F0 P0 F0fL P0prgL; apply (CaL A F0 P0) => //.
    by apply AaL.
  qed.

  local lemma Bad_bound:
    phoare [Exp'(C(A)).main : true ==>
      Bad P.logP F.m] <= ((qP * qF + (qP - 1) * qP %/ 2)%r / Support.card%r).
  proof.
  proc.
  seq 3: true
         1%r ((qP * qF + (qP - 1) * qP %/ 2)%r / Support.card%r)
         0%r 1%r
         (size P.logP <= qP /\ card (dom F.m) <= qF)=> //.
    inline Exp'(C(A)).A.a; wp.
    call (_: size P.logP = C.cP /\ C.cP <= qP /\
             card (dom F.m) <= C.cF /\ C.cF <= qF).
      (* prg *)
      proc; sp; if=> //.
      call (_: size P.logP = C.cP - 1 ==> size P.logP = C.cP).
        by proc; auto=> /#.
      by auto=> /#.
      (* f *)
      proc; sp; if=> //.
      call (_: card (dom F.m) < C.cF ==> card (dom F.m) <= C.cF).
      proc; auto=> /> &hr h r1 _ r2 _.
        by rewrite dom_set fcardU fcard1; smt w=fcard_ge0.
      by auto=> /#.
    inline *; auto=> />.
    by rewrite dom0 fcards0 /=; smt w=(ge0_qP ge0_qF).
  inline Resample.resample.
  exists* P.logP; elim* => logP.
  seq 3: true
         1%r  ((qP * qF + (qP - 1) * qP %/ 2)%r / Support.card%r)
         0%r 1%r
         (n = size logP /\ n <= qP /\ P.logP = [] /\
          card (dom F.m) <= qF)=> //.
    by rnd; wp.
  conseq (_ : _ : <= (if Bad P.logP F.m then 1%r else
      (sumid (qF + size P.logP) (qF + n))%r / Support.card%r)).
  + move=> /> &hr.
    have /= -> /= szlog_le_qP szm_le_qF := negBadE A AaL [] F.m{hr}.
    apply/ler_wpmul2r; first smt w=Support.card_gt0. apply/le_fromint.
    rewrite -{1}(@add0z qF) big_addn /= /predT -/predT.
    rewrite (@addzC qF) !addrK big_split big_constz.
    rewrite count_predT size_range /= max_ler ?size_ge0 addrC.
    rewrite ler_add 1:mulrC ?ler_wpmul2r // ?ge0_qF.
    rewrite sumidE ?size_ge0 leq_div2r // mulrC.
    move: (size_ge0 logP) szlog_le_qP => /IntOrder.ler_eqVlt [<- /#|gt0_sz le].
    by apply/IntOrder.ler_pmul => // /#.
  while{1} (n <= qP /\ card (dom F.m) <= qF).
    move=> Hw; exists* P.logP, F.m, n; elim* => logPw m n0.
    case: (Bad P.logP F.m).
      by conseq (_ : _ : <= (1%r))=> // /#.
    seq 2: (Bad P.logP F.m)
           ((qF + size logPw)%r / Support.card%r) 1%r 1%r
           ((sumid (qF + (size logPw + 1)) (qF + n))%r / Support.card%r)
           (n = n0 /\ F.m = m /\ r::logPw = P.logP /\
            n <= qP /\ card (dom F.m) <= qF)=> //.
      by wp; rnd=> //.
      wp; rnd; skip; progress.
      move: H2; rewrite !fromintD mulrDl (negBadE A AaL)=> //= -[Hu Hf].
      apply (ler_trans (mu dseed (predU (fun x, mem (dom F.m{hr}) x)
                                        (fun x, mem P.logP{hr} x)))).
        by apply mu_sub=> x [] /#.
      apply mu_or_le.
        rewrite (@ mu_eq _ _ (mem (dom F.m{hr}))) //.
        apply (ler_trans ((card (dom F.m{hr}))%r / Support.card%r)).
          apply mu_mem_le=> x _.
            by rewrite (@ dseed1E) /= /Support.card.
            by apply/ler_wpmul2r; [smt w=Support.card_gt0|exact/le_fromint].
          rewrite (@mu_eq _ _ (mem (P.logP{hr}))) //.
          by apply/mu_mem_le_size=> x _; rewrite dseed1E /Support.card.
        conseq Hw; progress=> //.
        by rewrite H1 /= (Ring.IntID.addrC 1) lerr.
      progress=> //; rewrite H2 /= -mulrDl addrA -fromintD.
      rewrite
        (@BIA.big_cat_int (qF + size P.logP{hr} + 1) (_ + List.size _))
        ?BIA.big_int1 /#.
    by skip; progress; smt ml=0.
  qed.

  lemma conclusion &m:
    Pr[Exp(C(A),F,P(F)).main() @ &m: res] <=
        Pr[Exp(C(A),F,PrgI).main() @ &m: res]
      + (qP * qF + (qP - 1) * qP %/ 2)%r / Support.card%r.
  proof.
  apply/(@ler_trans _ _ _ (pr &m)).
  have: Pr[Exp'(C(A)).main() @ &m: Bad P.logP F.m]
       <= (qP * qF + (qP - 1) * qP%/2)%r / Support.card%r
    by byphoare Bad_bound.
  smt ml=0.
  qed.
end section.