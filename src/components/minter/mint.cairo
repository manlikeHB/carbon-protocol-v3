#[starknet::component]
mod MintComponent {
    // Starknet imports

    use starknet::ContractAddress;
    use starknet::{get_caller_address, get_contract_address, get_block_timestamp};

    // External imports
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use openzeppelin::token::erc1155::interface::{IERC1155Dispatcher, IERC1155DispatcherTrait};

    // Internal imports

    use carbon_v3::components::minter::interface::IMint;
    use carbon_v3::components::minter::booking::{Booking, BookingStatus, BookingTrait};
    use carbon_v3::components::vintage::interface::{IVintageDispatcher, IVintageDispatcherTrait};
    use carbon_v3::contracts::project::{
        IExternalDispatcher as IProjectDispatcher,
        IExternalDispatcherTrait as IProjectDispatcherTrait
    };
    use carbon_v3::models::carbon_vintage::{CarbonVintage, CarbonVintageType};
    use carbon_v3::contracts::project::Project::{OWNER_ROLE};

    // Constants

    use carbon_v3::models::constants::{CC_DECIMALS_MULTIPLIER, MULTIPLIER_TONS_TO_MGRAMS};

    #[storage]
    struct Storage {
        Mint_carbonable_project_address: ContractAddress,
        Mint_payment_token_address: ContractAddress,
        Mint_public_sale_open: bool,
        Mint_min_money_amount_per_tx: u256,
        Mint_unit_price: u256,
        Mint_claimed_value: LegacyMap::<ContractAddress, u256>,
        Mint_remaining_money_amount: u256,
        Mint_cancel: bool,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        PublicSaleOpen: PublicSaleOpen,
        PublicSaleClose: PublicSaleClose,
        SoldOut: SoldOut,
        Buy: Buy,
        MintCanceled: MintCanceled,
        UnitPriceUpdated: UnitPriceUpdated,
        Withdraw: Withdraw,
        AmountRetrieved: AmountRetrieved,
        MinMoneyAmountPerTxUpdated: MinMoneyAmountPerTxUpdated,
    }

    #[derive(Drop, starknet::Event)]
    struct PublicSaleOpen {
        old_value: bool,
        new_value: bool
    }

    #[derive(Drop, starknet::Event)]
    struct PublicSaleClose {
        old_value: bool,
        new_value: bool
    }

    #[derive(Drop, starknet::Event)]
    struct SoldOut {}

    #[derive(Drop, starknet::Event)]
    struct Buy {
        #[key]
        address: ContractAddress,
        cc_amount: u256,
        vintages: Span<u256>,
    }

    #[derive(Drop, starknet::Event)]
    struct MintCanceled {
        old_value: bool,
        is_canceled: bool
    }

    #[derive(Drop, starknet::Event)]
    struct UnitPriceUpdated {
        old_price: u256,
        new_price: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct Withdraw {
        recipient: ContractAddress,
        amount: u256,
    }


    #[derive(Drop, starknet::Event)]
    struct AmountRetrieved {
        token_address: ContractAddress,
        recipient: ContractAddress,
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct MinMoneyAmountPerTxUpdated {
        old_amount: u256,
        new_amount: u256,
    }

    mod Errors {
        const INVALID_ARRAY_LENGTH: felt252 = 'Mint: invalid array length';
    }

    #[embeddable_as(MintImpl)]
    impl Mint<
        TContractState, +HasComponent<TContractState>, +Drop<TContractState>
    > of IMint<ComponentState<TContractState>> {
        fn get_carbonable_project_address(
            self: @ComponentState<TContractState>
        ) -> ContractAddress {
            self.Mint_carbonable_project_address.read()
        }

        fn get_payment_token_address(self: @ComponentState<TContractState>) -> ContractAddress {
            self.Mint_payment_token_address.read()
        }

        fn is_public_sale_open(self: @ComponentState<TContractState>) -> bool {
            self.Mint_public_sale_open.read()
        }

        fn get_unit_price(self: @ComponentState<TContractState>) -> u256 {
            self.Mint_unit_price.read()
        }

        fn get_available_money_amount(self: @ComponentState<TContractState>) -> u256 {
            self.Mint_remaining_money_amount.read()
        }

        fn get_min_money_amount_per_tx(self: @ComponentState<TContractState>) -> u256 {
            self.Mint_min_money_amount_per_tx.read()
        }

        fn is_sold_out(self: @ComponentState<TContractState>) -> bool {
            self.get_available_money_amount() == 0
        }

        fn cancel_mint(ref self: ComponentState<TContractState>, should_cancel: bool) {
            let project_address = self.Mint_carbonable_project_address.read();
            let project = IProjectDispatcher { contract_address: project_address };

            let caller_address = get_caller_address();
            assert(!caller_address.is_zero(), 'Invalid caller');
            let isOwner = project.only_owner(caller_address);
            assert(isOwner, 'Caller is not the owner');

            let old_value: bool = self.Mint_cancel.read();
            self.Mint_cancel.write(should_cancel);

            self.emit(MintCanceled { old_value: old_value, is_canceled: should_cancel });
        }

        fn is_canceled(self: @ComponentState<TContractState>) -> bool {
            self.Mint_cancel.read()
        }

        fn set_public_sale_open(ref self: ComponentState<TContractState>, public_sale_open: bool) {
            let project_address = self.Mint_carbonable_project_address.read();
            let project = IProjectDispatcher { contract_address: project_address };

            let caller_address = get_caller_address();
            assert(!caller_address.is_zero(), 'Invalid caller');
            let isOwner = project.only_owner(caller_address);
            assert(isOwner, 'Caller is not the owner');

            let old_value = self.Mint_public_sale_open.read();
            self.Mint_public_sale_open.write(public_sale_open);

            self.emit(PublicSaleOpen { old_value: old_value, new_value: public_sale_open });
        }

        fn set_unit_price(ref self: ComponentState<TContractState>, unit_price: u256) {
            let project_address = self.Mint_carbonable_project_address.read();
            let project = IProjectDispatcher { contract_address: project_address };

            let caller_address = get_caller_address();
            assert(!caller_address.is_zero(), 'Invalid caller');
            let isOwner = project.only_owner(caller_address);
            assert(isOwner, 'Caller is not the owner');
            assert(unit_price > 0, 'Invalid unit price');

            let old_price = self.Mint_unit_price.read();
            self.Mint_unit_price.write(unit_price);

            self.emit(UnitPriceUpdated { old_price: old_price, new_price: unit_price });
        }

        fn withdraw(ref self: ComponentState<TContractState>) {
            let project_address = self.Mint_carbonable_project_address.read();
            let project = IProjectDispatcher { contract_address: project_address };

            let caller_address = get_caller_address();
            assert(!caller_address.is_zero(), 'Invalid caller');
            let isOwner = project.only_owner(caller_address);
            assert(isOwner, 'Caller is not the owner');

            let token_address = self.Mint_payment_token_address.read();
            let erc20 = IERC20Dispatcher { contract_address: token_address };
            let contract_address = get_contract_address();
            let balance = erc20.balance_of(contract_address);

            let success = erc20.transfer(caller_address, balance);
            assert(success, 'Transfer failed');

            self.emit(Withdraw { recipient: caller_address, amount: balance });
        }

        fn retrieve_amount(
            ref self: ComponentState<TContractState>,
            token_address: ContractAddress,
            recipient: ContractAddress,
            amount: u256
        ) {
            let project_address = self.Mint_carbonable_project_address.read();
            let project = IProjectDispatcher { contract_address: project_address };

            let caller_address = get_caller_address();
            assert(!caller_address.is_zero(), 'Invalid caller');
            let isOwner = project.only_owner(caller_address);
            assert(isOwner, 'Caller is not the owner');

            let erc20 = IERC20Dispatcher { contract_address: token_address };
            let success = erc20.transfer(recipient, amount);
            assert(success, 'Transfer failed');

            self
                .emit(
                    AmountRetrieved {
                        token_address: token_address, recipient: recipient, amount: amount
                    }
                );
        }

        fn public_buy(ref self: ComponentState<TContractState>, cc_amount: u256) {
            let public_sale_open = self.Mint_public_sale_open.read();
            assert(public_sale_open, 'Sale is closed');

            self._buy(cc_amount);
        }

        fn set_min_money_amount_per_tx(
            ref self: ComponentState<TContractState>, min_money_amount_per_tx: u256
        ) {
            let project_address = self.Mint_carbonable_project_address.read();
            let project = IProjectDispatcher { contract_address: project_address };

            let caller_address = get_caller_address();
            assert(!caller_address.is_zero(), 'Invalid caller');
            let isOwner = project.only_owner(caller_address);
            assert(isOwner, 'Caller is not the owner');

            let max_money_amount_per_tx = project.get_max_money_amount();
            assert(
                max_money_amount_per_tx >= min_money_amount_per_tx,
                'Invalid min money amount per tx'
            );

            let old_amount = self.Mint_min_money_amount_per_tx.read();
            self.Mint_min_money_amount_per_tx.write(min_money_amount_per_tx);
            self
                .emit(
                    MinMoneyAmountPerTxUpdated {
                        old_amount: old_amount, new_amount: min_money_amount_per_tx,
                    }
                );
        }
    }

    #[generate_trait]
    impl InternalImpl<
        TContractState, +HasComponent<TContractState>, +Drop<TContractState>
    > of InternalTrait<TContractState> {
        fn initializer(
            ref self: ComponentState<TContractState>,
            carbonable_project_address: ContractAddress,
            payment_token_address: ContractAddress,
            public_sale_open: bool,
            max_money_amount: u256,
            unit_price: u256,
        ) {
            assert(unit_price > 0, 'Invalid unit price');
            self.Mint_carbonable_project_address.write(carbonable_project_address);
            self.Mint_payment_token_address.write(payment_token_address);
            self.Mint_unit_price.write(unit_price);
            self.Mint_remaining_money_amount.write(max_money_amount);
            self.Mint_public_sale_open.write(public_sale_open);
            let project = IProjectDispatcher { contract_address: carbonable_project_address };
            project.set_max_money_amount(max_money_amount);
        }

        fn _buy(ref self: ComponentState<TContractState>, cc_amount: u256) {
            assert(cc_amount > 0, 'Invalid carbon credit amount');

            let caller_address = get_caller_address();
            assert(!caller_address.is_zero(), 'Invalid caller');

            let unit_price = self.Mint_unit_price.read();
            // If user wants to buy 1 carbon credit, the input should be 1*MULTIPLIER_TONS_TO_MGRAMS
            let money_amount = cc_amount * unit_price / MULTIPLIER_TONS_TO_MGRAMS;
            println!("money_amount: {}", money_amount);
            println!("cc_amount: {}", cc_amount);

            let min_money_amount_per_tx = self.Mint_min_money_amount_per_tx.read();
            assert(money_amount >= min_money_amount_per_tx, 'Value too low');
            let remaining_money_amount = self.Mint_remaining_money_amount.read();
            assert(money_amount <= remaining_money_amount, 'Not enough remaining money');

            // [Interaction] Compute the amount of cc for each vintage
            let project_address = self.Mint_carbonable_project_address.read();
            let vintages = IVintageDispatcher { contract_address: project_address };
            let num_vintages: usize = vintages.get_num_vintages();

            let mut tokens_ids: Array<u256> = Default::default();
            let mut values_cc: Array<u256> = Default::default();
            let mut index = 0;
            loop {
                if index >= num_vintages {
                    break;
                }
                values_cc.append(cc_amount.into());
                tokens_ids.append(index.into());
                index += 1;
            };
            // [Interaction] Pay
            let token_address = self.Mint_payment_token_address.read();
            let erc20 = IERC20Dispatcher { contract_address: token_address };
            let minter_address = get_contract_address();

            let success = erc20.transfer_from(caller_address, minter_address, money_amount);
            // [Check] Transfer successful
            assert(success, 'Transfer failed');

            // [Interaction] Update remaining money amount
            self.Mint_remaining_money_amount.write(remaining_money_amount - money_amount);

            // [Interaction] Mint
            let project = IProjectDispatcher { contract_address: project_address };
            project.batch_mint(caller_address, tokens_ids.span(), values_cc.span());

            // [Event] Emit event
            self
                .emit(
                    Event::Buy(
                        Buy {
                            address: caller_address,
                            vintages: tokens_ids.span(),
                            cc_amount: cc_amount,
                        }
                    )
                );
        }
    }
}
