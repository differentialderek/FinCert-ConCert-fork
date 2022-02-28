From ConCert.Execution Require Import Blockchain.
From ConCert.Execution Require Import Containers.
From ConCert.Execution Require Import Serializable.
From ConCert.Execution.Examples Require Import BATCommon.
From ConCert.Execution.QCTests Require Import BATPrinters.
From ConCert.Execution.QCTests Require Import ChainPrinters.
From ConCert.Execution.QCTests Require Import EIP20TokenGens.
From ConCert.Execution.QCTests Require Import TestUtils.
From ConCert.Execution.QCTests Require Import TraceGens.
From QuickChick Require Import QuickChick.
Import QcNotation.
From ExtLib.Structures Require Import Monads.
Import MonadNotation. Open Scope monad_scope.
From Coq Require Import List.
From Coq Require Import ZArith.
Import ListNotations.


Module Type BATGensInfo.
  Parameter contract : Contract BATCommon.Setup BATCommon.Msg BATCommon.State.
  Parameter initial_chain : ChainBuilder.
  Parameter trace_length : nat.
  Parameter gAccount : Chain -> G Address.
  Parameter contract_addr : Address.
  Parameter accounts : list Address.
  Parameter accounts_total_balance : Z.
  Parameter bat_addr : Address.
  Parameter fund_addr : Address.
  Parameter bat_addr_refundable : bool.
  Parameter bat_addr_fundable : bool.
  Parameter eip20_transactions_before_finalized : bool.
End BATGensInfo.

Module BATGens (Info : BATGensInfo).
Import Info.
Arguments SerializedValue : clear implicits.
Arguments deserialize : clear implicits.
Arguments serialize : clear implicits.

Definition account_balance (env : Environment) (addr : Address) : Amount :=
  (env_account_balances env) addr.

Definition get_refundable_accounts state : list (G (option Address)) :=
  let balances_list := FMap.elements (balances state) in
  let filtered_balances := filter (fun x => (bat_addr_refundable || (negb (address_eqb bat_addr (fst x)))) && (0 <? (snd x))%N) balances_list in
    map returnGen (map Some (map fst filtered_balances)).

Definition get_fundable_accounts env : G (option Address) :=
  let freq_accounts := map (fun addr => (if bat_addr_fundable || (negb (address_eqb addr bat_addr)) then Z.to_nat (account_balance env addr) else 0, returnGenSome addr)) accounts in
    freq_ (returnGen None) freq_accounts.

Definition gFund_amount env state addr : G Z :=
  (choose (1, Z.min (account_balance env addr) (Z.of_N ((state.(tokenCreationCap) - (total_supply state)) / state.(tokenExchangeRate)))))%Z.

Definition gCreateTokens (env : Environment) (state : BATCommon.State) : GOpt (Address * Amount * Msg) :=
  let current_slot := S (current_slot (env_chain env)) in
  if (state.(isFinalized)
          || (Nat.ltb current_slot state.(fundingStart))
          || (Nat.ltb state.(fundingEnd) current_slot) (* Funding can only happen in funding period *)
          || (N.ltb (state.(tokenCreationCap) - (total_supply state)) state.(tokenExchangeRate))) (* No funding if cap was hit or we are too close to it *)
  then
    returnGen None
  else
    from_addr <- get_fundable_accounts env ;;
    value <- bindGen (gFund_amount env state from_addr) returnGenSome ;;
    returnGenSome (from_addr, value, create_tokens).

Definition gCreateTokensInvalid (env : Environment) (state : BATCommon.State) : GOpt (Address * Amount * Msg) :=
  from_addr <- get_fundable_accounts env ;;
  value <- bindGen (choose (1, account_balance env from_addr)%Z) returnGenSome ;;
  returnGenSome (from_addr, value, create_tokens).

Definition gRefund (env : Environment) (state : BATCommon.State) : GOpt (Address * Msg) :=
  let current_slot := S (current_slot (env_chain env)) in
  let accounts := get_refundable_accounts state in
  if ((state.(isFinalized)
          || (Nat.leb current_slot state.(fundingEnd))
          || (state.(tokenCreationMin) <=? (total_supply state))%N))
  then
    returnGen None
  else 
    from_addr <- oneOf_ (returnGen None) accounts ;;
    returnGenSome (from_addr, refund).

Definition gRefundInvalid (env : Environment) (state : BATCommon.State) : G (Address * Msg) :=
  from_addr <- gAccount env ;;
  returnGen (from_addr, refund).

Definition gFinalize (env : Environment) (state : BATCommon.State) : GOpt (Address * Msg) :=
  let current_slot := S (current_slot (env_chain env)) in
  if (state.(isFinalized)
        || ((total_supply state) <? state.(tokenCreationMin))%N
        || ((Nat.leb current_slot state.(fundingEnd)) && negb ((total_supply state) =? state.(tokenCreationCap))%N))
  then
    returnGen None
  else
    returnGenSome (fund_addr, finalize).

Definition gFinalizeInvalid (env : Environment) (state : BATCommon.State) : G (Address * Msg) :=
  from_addr <- gAccount env ;;
  returnGen (from_addr, finalize).

Module EIP20 := EIP20Gens Info.

Definition gTransfer (env : Environment) (state : BATCommon.State) : GOpt (Address * Msg) :=
  if eip20_transactions_before_finalized || state.(isFinalized)
  then
    '(caller, msg) <- EIP20.gTransfer env (token_state state) ;;
    returnGenSome (caller, tokenMsg msg)
  else
    returnGen None.

Definition gApprove (state : BATCommon.State) : GOpt (Address * Msg) :=
  if eip20_transactions_before_finalized || state.(isFinalized)
  then
    bindGenOpt (EIP20.gApprove (token_state state))
        (fun '(caller, msg) => returnGenSome (caller, tokenMsg msg))
  else
    returnGen None.

Definition gTransfer_from (state : BATCommon.State) : GOpt (Address * Msg) :=
  if eip20_transactions_before_finalized || state.(isFinalized)
  then
    bindGenOpt (EIP20.gTransfer_from (token_state state))
        (fun '(caller, msg) => returnGenSome (caller, tokenMsg msg))
  else
    returnGen None.

(* BAT valid call generator 
   Generator that will always return BAToken contract calls that are valid on their own,
   i.e. guaranteed to be valid if it is the first action executed in the block.
*)
Definition gBATActionValid (env : Environment) : GOpt Action :=
  let call contract_addr caller_addr value msg :=
    returnGenSome (build_act caller_addr caller_addr (act_call contract_addr value ((@serialize BATCommon.Msg _) msg))) in
  state <- returnGen (get_contract_state BATCommon.State env contract_addr) ;;
  backtrack [
    (* transfer *)
    (1, bindGenOpt (gTransfer env state)
        (fun '(caller, msg) =>
          call contract_addr caller (0%Z) msg
        )
    );
    (* transfer_from *)
    (2, bindGenOpt (gTransfer_from state)
        (fun '(caller, msg) =>
          call contract_addr caller (0%Z) msg
        )
    );
    (* approve *)
    (1, bindGenOpt (gApprove state)
        (fun '(caller, msg) =>
          call contract_addr caller (0%Z) msg
        )
    );
    (* create_tokens *)
    (5, bindGenOpt (gCreateTokens env state)
        (fun '(caller, value, msg) =>
          call contract_addr caller value msg
        )
    );
    (* refund *)
    (10, bindGenOpt (gRefund env state)
        (fun '(caller, msg) =>
          call contract_addr caller (0%Z) msg
        )
    );
    (* finalize *)
    (10, bindGenOpt (gFinalize env state)
        (fun '(caller, msg) =>
          call contract_addr caller (0%Z) msg
        )
    )
  ].

(* BAT invalid call generator 
   Generator likely to generate invalid BAToken contract calls.
   It treats the BAToken code mostly as blackbox and only know the expected types of input
    but does not make any assumptions/checks on which values will result in valid or invalid calls
*)
Definition gBATActionInvalid (env : Environment) : GOpt Action :=
  let call contract_addr caller_addr value msg :=
    returnGenSome (build_act caller_addr caller_addr (act_call contract_addr value ((@serialize BATCommon.Msg _) msg))) in
  state <- returnGen (get_contract_state BATCommon.State env contract_addr) ;;
  backtrack [
    (* transfer *)
    (1, '(caller, msg) <- EIP20.gTransfer env (token_state state) ;;
        call contract_addr caller (0%Z) (tokenMsg msg)
    ) ;
    (* transfer_from *)
    (2, bindGenOpt (EIP20.gTransfer_from (token_state state))
        (fun '(caller, msg) =>
          call contract_addr caller (0%Z) (tokenMsg msg)
        )
    );
    (* approve *)
    (1, bindGenOpt (EIP20.gApprove (token_state state))
        (fun '(caller, msg) =>
          call contract_addr caller (0%Z) (tokenMsg msg)
        )
    );
    (* create_tokens *)
    (5, bindGenOpt (gCreateTokensInvalid env state)
        (fun '(caller, value, msg) =>
          call contract_addr caller value msg
        )
    );
    (* refund *)
    (1, '(caller, msg) <- gRefundInvalid env state ;;
        call contract_addr caller (0%Z) msg
    );
    (* finalize *)
    (1, '(caller, msg) <- gFinalizeInvalid env state ;;
        call contract_addr caller (0%Z) msg
    )
  ].

(* BAT call generator
   Has a 7% chance to attempt to generate an invalid contract call
    More specifically it has:
    - 0.5% chance of generating a valid call and then replacing the amount of money sent with that call.
      For BAT contract this is likely to result in an invalid call as most contract calls on BAToken are 
      not allowed to include money in them.
    - 6.5% chance of using the invalid action generator. This generator is likely to generate an invalid call
      since it treats the contract as a black box and thus does not check any of the expected requirements for
      a contract call to be valid.
    The reamaining 90% of the time it will generate a call that is guaranteed to be valid (only guaranteed to
    be valid on its own, since the generator cannot know what other calls may be included in the same block and
    which order they will be executed in)
*)
Definition gBATAction (env : Environment) : GOpt Action :=
  state <- returnGen (get_contract_state BATCommon.State env contract_addr) ;;
  freq [
    (5, bindGenOpt (gBATActionValid env)
        (fun '(action) =>
          match action.(act_body) with
          | act_transfer _ _ => returnGen None
          | act_deploy _ _ _ => returnGen None
          | act_call to _ msg =>
            amount <- choose (0, account_balance env action.(act_from))%Z ;;
            returnGenSome (build_act action.(act_from) action.(act_from) (act_call to amount msg))
          end
        ));
    (65, gBATActionInvalid env);
    (930, gBATActionValid env)
  ].

Definition gBATSetup : G Setup :=
  fundingStart <- choose (0, (trace_length - 1)) ;;
  fundingEnd <- choose (0, (trace_length - 1)) ;;
  exchangeRate <- choose (0, Z.to_N accounts_total_balance)%N ;;
  initSupply <- choose (0, Z.to_N accounts_total_balance)%N ;;
  tokenMin <- choose (0, Z.to_N accounts_total_balance)%N ;;
  tokenCap <- choose (0, Z.to_N accounts_total_balance)%N ;;
  returnGen (BATCommon.build_setup initSupply
                             fund_addr
                             bat_addr
                             fundingStart
                             fundingEnd
                             exchangeRate
                             tokenCap
                             tokenMin).

(* chain generator *)
Definition gTokenChain max_acts_per_block token_cb max_length :=
  let act_depth := 1 in
  gChain token_cb
    (fun env act_depth => gBATAction env) max_length act_depth max_acts_per_block.

(* Generator for debugging Action generator *)
Definition gInvalidActions max_acts_per_block token_cb max_length g :=
  let act_depth := 1 in
  gInvalidAction token_cb
    (fun env act_depth => g env) max_length act_depth max_acts_per_block.

Definition forAllInvalidActions n g P :=
  let max_acts_per_block := 1 in
  forAll (gInvalidActions max_acts_per_block initial_chain n g)
    (fun '(cb, acts) => if length acts =? 0
                        then checker true
                        else disjoin (map (fun act => P cb act) acts)).

Definition forAllTokenChainBuilders n :=
  let max_acts_per_block := 2 in
  forAllChainBuilder n initial_chain (gTokenChain max_acts_per_block).

Definition forAllTokenBlocks n :=
  let max_acts_per_block := 2 in
  forAllBlocks n initial_chain (gTokenChain max_acts_per_block).

Definition forAllTokenChainStates n :=
  let max_acts_per_block := 2 in
  forAllChainState n initial_chain (gTokenChain max_acts_per_block).

Definition pre_post_assertion_token P c Q :=
  let max_acts_per_block := 2 in
  let trace_length := 7 in
  pre_post_assertion trace_length initial_chain (gTokenChain max_acts_per_block) contract c P Q.

Definition reachableFrom_implication init_cb (P : ChainState -> bool) Q :=
  let P' := fun cs => if P cs then Some true else None in
  let Q' := fun _ pre_trace post_trace =>
    checker (fold_left (fun a (cs : ChainState) => a && (Q pre_trace cs) ) post_trace true) in
  let max_acts_per_block := 2%nat in
  let trace_length := 7%nat in
  reachableFrom_implies_chaintracePropSized trace_length init_cb
                                            (gTokenChain max_acts_per_block) P' Q'.

Notation "cb '~~>' pf" :=
  (reachableFrom_chaintrace cb (gTokenChain 2) pf) (at level 45, no associativity).
Notation "'{' lc '~~~>' pf1 '===>' pf2 '}'" :=
  (reachableFrom_implication lc pf1 pf2) (at level 90, left associativity).
Notation "'{{' P '}}'" := (forAllTokenChainStates 7 P) (at level 60, no associativity).
Notation "'{{' P '}}' '==>' '{{' Q '}}'" :=
  (forAllChainState_implication 7 initial_chain (gTokenChain 2) P Q) (at level 60, left associativity).
Notation "'{{' P '}}' c '{{' Q '}}'" :=
  (pre_post_assertion_token P c Q) (at level 60, c at next level, no associativity).

End BATGens.
