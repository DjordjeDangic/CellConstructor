module get_lf

    contains

    subroutine calculate_lineshapes(irrqgrid, qgrid, weights, scatt_events, qe_zeu, fc2, r2_2, &
                    fc3, r3_2, r3_3, rprim, dielectric_tensor, pos, masses, smear, smear_id, T, &
                    qe_alat, gaussian, classical, long_range, energies, ne, nirrqpt, nat, nfc2, &
                    nfc3, n_events, lineshapes)

        use omp_lib
        use third_order_cond

        implicit none

        integer, parameter :: DP = selected_real_kind(14,200)
        real(kind=DP), parameter :: PI = 3.141592653589793115997963468544185161590576171875, A_TO_BOHR = 1.889725989_DP

        integer, intent(in) :: nirrqpt, nat, nfc2, nfc3, ne, n_events
        integer, intent(in) :: weights(n_events), scatt_events(nirrqpt)
        real(kind=DP), intent(in) :: irrqgrid(3, nirrqpt)
        real(kind=DP), intent(in) :: qgrid(3, n_events)
        real(kind=DP), intent(in) :: qe_zeu(3, 3, nat)
        real(kind=DP), intent(in) :: fc2(nfc2, 3*nat, 3*nat)
        real(kind=DP), intent(in) :: fc3(nfc3, 3*nat, 3*nat, 3*nat)
        real(kind=DP), intent(in) :: r2_2(3, nfc2)
        real(kind=DP), intent(in) :: r3_2(3, nfc3), r3_3(3, nfc3)
        real(kind=DP), intent(in) :: rprim(3, 3), dielectric_tensor(3,3)
        real(kind=DP), intent(in) :: pos(3, nat)
        real(kind=DP), intent(in) :: masses(nat), energies(ne)
        real(kind=DP), intent(in) :: smear(3*nat, nirrqpt), smear_id(3*nat, nirrqpt)
        real(kind=DP), intent(in) :: T, qe_alat
        logical, intent(in) :: gaussian, classical, long_range
        real(kind=DP), dimension(nirrqpt, 3*nat, ne), intent(out) :: lineshapes

        integer :: iqpt, i, jqpt, tot_qpt, prev_events, nthreads
        real(kind=DP), dimension(3) :: qpt, qe_q
        real(kind=DP), dimension(3,3) :: kprim, qe_bg
        real(kind=DP), dimension(3,nat) :: qe_tau
        real(kind=DP), dimension(3*nat) :: w2_q, w_q
        real(kind=DP) :: qe_omega
!        real(kind=DP), dimension(ne, 3*nat) :: lineshape
        real(kind=DP), allocatable, dimension(:, :) :: lineshape
        complex(kind=DP), allocatable, dimension(:, :) :: self_energy
!        complex(kind=DP), dimension(ne, 3*nat) :: self_energy
        complex(kind=DP), dimension(3*nat,3*nat) :: pols_q, d2_q
        real(kind=DP), allocatable, dimension(:,:) :: curr_grid
        integer, allocatable, dimension(:) :: curr_w
        logical :: is_q_gamma, w_neg_freqs, parallelize

        lineshapes(:,:,:) = 0.0_DP
        kprim = transpose(inv(rprim))
        nthreads = omp_get_max_threads()
        print*, 'Maximum number of threads available: ', nthreads

        parallelize = .True.
        if(nirrqpt <= nthreads) then
                parallelize = .False.
        endif
!        print*, 'Got parallelize'

        qe_tau = pos * A_TO_BOHR / qe_alat
        qe_bg = inv(rprim)*qe_alat / (A_TO_BOHR)
        qe_omega = abs(dot_product(cross(rprim(1,:), rprim(2,:)) , rprim(3,:))*A_TO_BOHR**3)

        !$OMP PARALLEL DO IF(parallelize) DEFAULT(NONE) &
        !$OMP PRIVATE(iqpt, w_neg_freqs, qpt, qe_q, w2_q, pols_q, d2_q, is_q_gamma, self_energy, &
        !$OMP curr_grid, w_q, curr_w, prev_events, tot_qpt, lineshape) &
        !$OMP SHARED(nirrqpt, nfc2, nat, qe_zeu, fc2, r2_2, masses, kprim, dielectric_tensor, qe_bg, scatt_events, &
        !$OMP nfc3, ne, fc3, r3_2, r3_3, pos, qe_tau, smear, T, qe_alat, qe_omega, energies, parallelize, smear_id, lineshapes, &
        !$OMP irrqgrid, qgrid, weights, gaussian, classical, long_range)
        do iqpt = 1, nirrqpt
            allocate(lineshape(ne, 3*nat), self_energy(ne, 3*nat))
!            print*, iqpt
            w_neg_freqs = .False.
            print*, 'Calculating ', iqpt, ' point in the irreducible zone out of ', nirrqpt, '!'
            lineshape(:,:) = 0.0_DP 
            qpt = irrqgrid(:, iqpt) 
            qe_q = qpt*qe_alat/A_TO_BOHR

            !call interpolate_fc2(nfc2, nat, fc2, r2_2, masses, pos, qpt, w2_q, pols_q, d2_q)
            call interpolate_fc2(nfc2, nat, fc2, qe_zeu, dielectric_tensor, qe_bg, r2_2, masses, pos, qe_tau, &
                               qpt, qe_q, qe_omega, qe_alat, long_range, w2_q, pols_q, d2_q)
            call check_if_gamma(nat, qpt, kprim, w2_q, is_q_gamma)

            if(any(w2_q < 0.0_DP)) then
                print*, 'Negative eigenvalue of dynamical matrix!'
                w_neg_freqs = .True.
            endif
!            print*, 'Interpolate frequency'
            if(.not. w_neg_freqs) then
                w_q = sqrt(w2_q)
                self_energy(:,:) = complex(0.0_DP, 0.0_DP)
                allocate(curr_grid(3, scatt_events(iqpt)))
                allocate(curr_w(scatt_events(iqpt)))
                if(iqpt > 1) then
                    prev_events = sum(scatt_events(1:iqpt-1))
                else
                    prev_events = 0
                endif
                do jqpt = 1, scatt_events(iqpt)
                    curr_grid(:,jqpt) = qgrid(:,prev_events + jqpt)
                    curr_w(jqpt) = weights(prev_events + jqpt)
                enddo
!                print*, 'Got grids'
                call calculate_self_energy_P(w_q, qpt, pols_q, is_q_gamma, scatt_events(iqpt), nat, nfc2, &
                    nfc3, ne, curr_grid, curr_w, qe_zeu, fc2, fc3, r2_2, r3_2, r3_3, pos, kprim, dielectric_tensor,&
                    masses, smear(:,iqpt), T, qe_alat, energies, .not. parallelize, gaussian, classical, long_range, self_energy) 
                deallocate(curr_grid)
                tot_qpt = sum(curr_w)
                deallocate(curr_w)
                self_energy = self_energy/dble(tot_qpt)
                if(any(self_energy .ne. self_energy)) then
                        print*, 'NaN in self_energy'
                endif
                if(gaussian) then
                        call calculate_real_part_via_Kramers_Kronig(ne, 3*nat, self_energy, energies, w_q)
                        !call hilbert_transform_via_FFT(ne, 3*nat, self_energy)
                        if(any(self_energy .ne. self_energy)) then
                                print*, 'NaN in Kramers Kronig'
                        endif
                endif

                call compute_spectralf_diag_single(smear_id(:, iqpt), energies, w_q, self_energy, nat, ne, lineshape)
                !call calculate_spectral_function(energies, w_q, self_energy, nat, ne, lineshape)
                !call calculate_correlation_function(energies, w_q, self_energy, nat, ne, lineshape)

                do i = 1, 3*nat
                    if(w_q(i) .ne. 0.0_DP) then
                        lineshapes(iqpt, i, :) = lineshape(:,i) 
                    else
                        lineshapes(iqpt, i, :) = 0.0_DP
                    endif
                enddo
            else
                lineshapes(iqpt,:,:) = 0.0_DP
            endif
            deallocate(lineshape, self_energy)

        enddo
        !$OMP END PARALLEL DO


    end subroutine calculate_lineshapes


    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

    subroutine calculate_lineshapes_mode_mixing(irrqgrid, qgrid, weights, scatt_events, qe_zeu, fc2, r2_2, &
                    fc3, r3_2, r3_3, rprim, dielectric_tensor, pos, masses, smear, smear_id, T, &
                    qe_alat, gaussian, classical, long_range, energies, ne, nirrqpt, nat, nfc2, &
                    nfc3, n_events, lineshapes)

        use omp_lib
        use third_order_cond

        implicit none

        integer, parameter :: DP = selected_real_kind(14,200)
        real(kind=DP), parameter :: PI = 3.141592653589793115997963468544185161590576171875, A_TO_BOHR = 1.889725989_DP

        integer, intent(in) :: nirrqpt, nat, nfc2, nfc3, ne, n_events
        integer, intent(in) :: weights(n_events), scatt_events(nirrqpt)
        real(kind=DP), intent(in) :: irrqgrid(3, nirrqpt)
        real(kind=DP), intent(in) :: qgrid(3, n_events)
        real(kind=DP), intent(in) :: qe_zeu(3, 3, nat)
        real(kind=DP), intent(in) :: fc2(nfc2, 3*nat, 3*nat)
        real(kind=DP), intent(in) :: fc3(nfc3, 3*nat, 3*nat, 3*nat)
        real(kind=DP), intent(in) :: r2_2(3, nfc2)
        real(kind=DP), intent(in) :: r3_2(3, nfc3), r3_3(3, nfc3)
        real(kind=DP), intent(in) :: rprim(3, 3), dielectric_tensor(3,3)
        real(kind=DP), intent(in) :: pos(3, nat)
        real(kind=DP), intent(in) :: masses(nat), energies(ne)
        real(kind=DP), intent(in) :: smear(3*nat, nirrqpt), smear_id(3*nat, nirrqpt)
        real(kind=DP), intent(in) :: T, qe_alat
        logical, intent(in) :: gaussian, classical, long_range
        complex(kind=DP), dimension(nirrqpt, 3*nat, 3*nat, ne), intent(out) :: lineshapes

        integer :: iqpt, i, ie, jqpt, tot_qpt, prev_events, nthreads, iband, jband
        integer :: iband1, jband1
        real(kind=DP), dimension(3) :: qpt, qe_q
        real(kind=DP), dimension(3,3) :: kprim, qe_bg
        real(kind=DP), dimension(3,nat) :: qe_tau
        real(kind=DP), dimension(3*nat) :: w2_q, w_q
        real(kind=DP) :: qe_omega 
!        real(kind=DP), dimension(ne, 3*nat) :: lineshape
        complex(kind=DP), allocatable, dimension(:,:,:) :: lineshape
        complex(kind=DP), allocatable, dimension(:, :, :) :: self_energy
!        complex(kind=DP), dimension(ne, 3*nat) :: self_energy
        complex(kind=DP), dimension(3*nat,3*nat) :: pols_q, d2_q
        real(kind=DP), allocatable, dimension(:,:) :: curr_grid
        integer, allocatable, dimension(:) :: curr_w
        logical :: is_q_gamma, w_neg_freqs, parallelize

        ! Get non-diagonal lineshapes but in mode basis

        lineshapes(:,:,:,:) = complex(0.0_DP, 0.0_DP)
        kprim = transpose(inv(rprim))
        nthreads = omp_get_max_threads()
        print*, 'Maximum number of threads available: ', nthreads

        parallelize = .True.
        if(nirrqpt <= nthreads) then
                parallelize = .False.
        endif
!        print*, 'Got parallelize'
        qe_tau = pos * A_TO_BOHR / qe_alat
        qe_bg = inv(rprim)*qe_alat / (A_TO_BOHR)
        qe_omega = abs(dot_product(cross(rprim(1,:), rprim(2,:)) , rprim(3,:))*A_TO_BOHR**3)

        !$OMP PARALLEL DO IF(parallelize) DEFAULT(NONE) &
        !$OMP PRIVATE(iqpt, w_neg_freqs, qpt, qe_q, w2_q, pols_q, is_q_gamma, self_energy, &
        !$OMP curr_grid, w_q, curr_w, prev_events, tot_qpt, d2_q, lineshape) &
        !$OMP SHARED(nirrqpt, nfc2, nat, qe_zeu, fc2, r2_2, masses, kprim, dielectric_tensor, qe_bg, scatt_events, &
        !$OMP nfc3, ne, fc3, r3_2, r3_3, pos, qe_tau, smear, T, qe_alat, qe_omega, energies, parallelize, smear_id, &
        !$OMP lineshapes, irrqgrid, qgrid, weights, gaussian, classical, long_range)
        do iqpt = 1, nirrqpt
            allocate(lineshape(3*nat, 3*nat, ne), self_energy(ne, 3*nat, 3*nat))
!            print*, iqpt
            w_neg_freqs = .False.
            print*, 'Calculating ', iqpt, ' point in the irreducible zone out of ', nirrqpt, '!'
            lineshape(:,:,:) = 0.0_DP 
            qpt = irrqgrid(:, iqpt) 
            qe_q = qpt*qe_alat/A_TO_BOHR
            !call interpolate_fc2(nfc2, nat, fc2, r2_2, masses, pos, qpt, w2_q, pols_q, d2_q)
            call interpolate_fc2(nfc2, nat, fc2, qe_zeu, dielectric_tensor, qe_bg, r2_2, masses, pos, qe_tau, &
                               qpt, qe_q, qe_omega, qe_alat, long_range, w2_q, pols_q, d2_q)
            call check_if_gamma(nat, qpt, kprim, w2_q, is_q_gamma)

            if(any(w2_q < 0.0_DP)) then
                print*, 'Negative eigenvalue of dynamical matrix!'
                w_neg_freqs = .True.
            endif
!            print*, 'Interpolate frequency'
            if(.not. w_neg_freqs) then
                w_q = sqrt(w2_q)
                self_energy(:,:,:) = complex(0.0_DP, 0.0_DP)
                allocate(curr_grid(3, scatt_events(iqpt)))
                allocate(curr_w(scatt_events(iqpt)))
                if(iqpt > 1) then
                    prev_events = sum(scatt_events(1:iqpt-1))
                else
                    prev_events = 0
                endif
                do jqpt = 1, scatt_events(iqpt)
                    curr_grid(:,jqpt) = qgrid(:,prev_events + jqpt)
                    curr_w(jqpt) = weights(prev_events + jqpt)
                enddo
                call calculate_self_energy_full(w_q, qpt, pols_q, is_q_gamma, scatt_events(iqpt), nat, nfc2, &
                    nfc3, ne, curr_grid, curr_w, qe_zeu, fc2, fc3, r2_2, r3_2, r3_3, pos, kprim, dielectric_tensor, &
                    masses, smear(:,iqpt), T, qe_alat, &
                    energies, .not. parallelize, gaussian, classical, long_range, self_energy) 
                deallocate(curr_grid)
                tot_qpt = sum(curr_w)
                deallocate(curr_w)
                self_energy = self_energy/dble(tot_qpt)
                if(gaussian) then
                        call calculate_real_part_via_Kramers_Kronig_2d(ne, 3*nat, self_energy, energies, w_q)
                        !call hilbert_transform_via_FFT(ne, 3*nat, self_energy) ! not much better
                        if(any(self_energy .ne. self_energy)) then
                                print*, 'NaN in Kramers Kronig'
                        endif
                endif
                if(any(self_energy .ne. self_energy)) then
                        print*, 'NaN in self_energy'
                endif

                call calculate_spectral_function_mode_mixing(energies, smear_id(:, iqpt), &
                        w_q,self_energy,is_q_gamma,lineshape,masses,nat,ne)

                lineshape = lineshape*2.0_DP
                lineshapes(iqpt, :, :, :) = lineshape
                ! projected them to Cartesian coordinates. Leave it for debugging
                !do iband = 1, 3*nat
                !        do jband = 1, 3*nat
                !                do iband1 = 1, 3*nat
                !                do jband1 = 1, 3*nat
                !                        lineshapes(iqpt, jband, iband, :) = lineshapes(iqpt, jband, iband, :) + &
                !                        lineshape(jband1,iband1,:)*pols_q(jband,jband1)*conjg(pols_q(iband,iband1))
                !                enddo
                !                enddo
                !        enddo
                !enddo
            else
                lineshapes(iqpt,:,:,:) = complex(0.0_DP, 0.0_DP)
            endif
            deallocate(lineshape, self_energy)

        enddo
        !$OMP END PARALLEL DO


    end subroutine calculate_lineshapes_mode_mixing

    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

    subroutine calculate_lineshapes_cartesian(irrqgrid, qgrid, weights, scatt_events, qe_zeu, fc2, r2_2, &
                    fc3, r3_2, r3_3, rprim, dielectric_tensor, pos, masses, smear, smear_id, T, &
                    qe_alat, gaussian, classical, long_range, energies, ne, nirrqpt, nat, nfc2, &
                    nfc3, n_events, lineshapes)

        use omp_lib
        use third_order_cond

        implicit none

        integer, parameter :: DP = selected_real_kind(14,200)
        real(kind=DP), parameter :: PI = 3.141592653589793115997963468544185161590576171875, A_TO_BOHR = 1.889725989_DP

        integer, intent(in) :: nirrqpt, nat, nfc2, nfc3, ne, n_events
        integer, intent(in) :: weights(n_events), scatt_events(nirrqpt)
        real(kind=DP), intent(in) :: irrqgrid(3, nirrqpt)
        real(kind=DP), intent(in) :: qgrid(3, n_events)
        real(kind=DP), intent(in) :: qe_zeu(3, 3, nat)
        real(kind=DP), intent(in) :: fc2(nfc2, 3*nat, 3*nat)
        real(kind=DP), intent(in) :: fc3(nfc3, 3*nat, 3*nat, 3*nat)
        real(kind=DP), intent(in) :: r2_2(3, nfc2)
        real(kind=DP), intent(in) :: r3_2(3, nfc3), r3_3(3, nfc3)
        real(kind=DP), intent(in) :: rprim(3, 3), dielectric_tensor(3,3)
        real(kind=DP), intent(in) :: pos(3, nat)
        real(kind=DP), intent(in) :: masses(nat), energies(ne)
        real(kind=DP), intent(in) :: smear(3*nat, nirrqpt), smear_id(3*nat, nirrqpt)
        real(kind=DP), intent(in) :: T, qe_alat
        logical, intent(in) :: gaussian, classical, long_range
        complex(kind=DP), dimension(nirrqpt, 3*nat, 3*nat, ne), intent(out) :: lineshapes

        integer :: iqpt, i, ie, jqpt, tot_qpt, prev_events, nthreads, iband, jband
        integer :: iband1, jband1
        real(kind=DP), dimension(3) :: qpt, qe_q
        real(kind=DP), dimension(3,3) :: kprim, qe_bg
        real(kind=DP), dimension(3,nat) :: qe_tau
        real(kind=DP) :: qe_omega
        real(kind=DP), dimension(3*nat) :: w2_q, w_q
!        real(kind=DP), dimension(ne, 3*nat) :: lineshape
        complex(kind=DP), allocatable, dimension(:,:,:) :: lineshape
        complex(kind=DP), allocatable, dimension(:, :, :) :: self_energy, self_energy_cart
!        complex(kind=DP), dimension(ne, 3*nat) :: self_energy
        complex(kind=DP), dimension(3*nat,3*nat) :: pols_q, d2_q
        real(kind=DP), allocatable, dimension(:,:) :: curr_grid
        integer, allocatable, dimension(:) :: curr_w
        logical :: is_q_gamma, w_neg_freqs, parallelize


        lineshapes(:,:,:,:) = 0.0_DP
        kprim = transpose(inv(rprim))
        nthreads = omp_get_max_threads()
        print*, 'Maximum number of threads available: ', nthreads

        parallelize = .True.
        if(nirrqpt <= nthreads) then
                parallelize = .False.
        endif
!        print*, 'Got parallelize'
        qe_tau = pos * A_TO_BOHR / qe_alat
        qe_bg = inv(rprim)*qe_alat / (A_TO_BOHR)
        qe_omega = abs(dot_product(cross(rprim(1,:), rprim(2,:)) , rprim(3,:))*A_TO_BOHR**3)

        !$OMP PARALLEL DO IF(parallelize) DEFAULT(NONE) &
        !$OMP PRIVATE(iqpt, w_neg_freqs, qpt, qe_q, w2_q, pols_q, is_q_gamma, self_energy, &
        !$OMP curr_grid, w_q, curr_w, prev_events, tot_qpt, self_energy_cart, d2_q, lineshape) &
        !$OMP SHARED(nirrqpt, nfc2, nat, qe_zeu, fc2, r2_2, masses, kprim, dielectric_tensor, qe_bg, scatt_events, &
        !$OMP nfc3, ne, fc3, r3_2, r3_3, pos, qe_tau, smear, T, qe_alat, qe_omega, energies, parallelize, smear_id,&
        !$OMP lineshapes, irrqgrid, qgrid, weights, gaussian, classical, long_range)
        do iqpt = 1, nirrqpt
            allocate(lineshape(3*nat, 3*nat, ne), self_energy(ne, 3*nat, 3*nat), self_energy_cart(ne, 3*nat, 3*nat))
!            print*, iqpt
            w_neg_freqs = .False.
            print*, 'Calculating ', iqpt, ' point in the irreducible zone out of ', nirrqpt, '!'
            lineshape(:,:,:) = 0.0_DP 
            qpt = irrqgrid(:, iqpt) 
            qe_q = qpt*qe_alat/A_TO_BOHR
            !call interpolate_fc2(nfc2, nat, fc2, r2_2, masses, pos, qpt, w2_q, pols_q, d2_q)
            call interpolate_fc2(nfc2, nat, fc2, qe_zeu, dielectric_tensor, qe_bg, r2_2, masses, pos, qe_tau, &
                               qpt, qe_q, qe_omega, qe_alat, long_range, w2_q, pols_q, d2_q)
            call check_if_gamma(nat, qpt, kprim, w2_q, is_q_gamma)

            if(any(w2_q < 0.0_DP)) then
                print*, 'Negative eigenvalue of dynamical matrix!'
                w_neg_freqs = .True.
            endif
!            print*, 'Interpolate frequency'
            if(.not. w_neg_freqs) then
                w_q = sqrt(w2_q)
                self_energy(:,:,:) = complex(0.0_DP, 0.0_DP)
                self_energy_cart(:,:,:) = complex(0.0_DP, 0.0_DP)
                allocate(curr_grid(3, scatt_events(iqpt)))
                allocate(curr_w(scatt_events(iqpt)))
                if(iqpt > 1) then
                    prev_events = sum(scatt_events(1:iqpt-1))
                else
                    prev_events = 0
                endif
                do jqpt = 1, scatt_events(iqpt)
                    curr_grid(:,jqpt) = qgrid(:,prev_events + jqpt)
                    curr_w(jqpt) = weights(prev_events + jqpt)
                enddo
!                print*, 'Got grids'
                call calculate_self_energy_full(w_q, qpt, pols_q, is_q_gamma, scatt_events(iqpt), nat, nfc2, &
                    nfc3, ne, curr_grid, curr_w, qe_zeu, fc2, fc3, r2_2, r3_2, r3_3, pos, kprim, &
                    dielectric_tensor, masses, smear(:,iqpt), T, qe_alat, &
                    energies, .not. parallelize, gaussian, classical, long_range, self_energy) 
                deallocate(curr_grid)
                tot_qpt = sum(curr_w)
                deallocate(curr_w)
                self_energy = self_energy/dble(tot_qpt)
                if(gaussian) then
                        call calculate_real_part_via_Kramers_Kronig_2d(ne, 3*nat, self_energy, energies, w_q)
                        !call hilbert_transform_via_FFT(ne, 3*nat, self_energy)
                        if(any(self_energy .ne. self_energy)) then
                                print*, 'NaN in Kramers Kronig'
                        endif
                endif
                if(any(self_energy .ne. self_energy)) then
                        print*, 'NaN in self_energy'
                endif
                do iband = 1, 3*nat
                        do jband = 1, 3*nat
                                do iband1 = 1, 3*nat
                                do jband1 = 1, 3*nat
                                        self_energy_cart(:, jband, iband) = self_energy_cart(:, jband, iband) + &
                                        self_energy(:,jband1,iband1)*pols_q(jband,jband1)*conjg(pols_q(iband,iband1))
                                enddo
                                enddo
                        enddo
                enddo

                call calculate_spectral_function_cartesian(energies, smear_id(:, iqpt), &
                        d2_q,self_energy_cart,is_q_gamma,lineshape,masses,nat,ne)

                lineshapes(iqpt, :, :, :) = lineshape*2.0_DP
            else
                lineshapes(iqpt,:,:,:) = 0.0_DP
            endif
            deallocate(lineshape, self_energy, self_energy_cart)

        enddo
        !$OMP END PARALLEL DO


    end subroutine calculate_lineshapes_cartesian


    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

    subroutine calculate_lifetimes_selfconsistently(irrqgrid, qgrid, weights, scatt_events, qe_zeu, fc2, r2_2, &
                    fc3, r3_2, r3_3, rprim, dielectric_tensor, pos, masses, smear, smear_id, T, qe_alat, gaussian, &
                    classical, long_range, energies, ne, nirrqpt, nat, nfc2, nfc3, n_events, selfengs)

        use omp_lib
        use third_order_cond

        implicit none

        integer, parameter :: DP = selected_real_kind(14,200)
        real(kind=DP), parameter :: PI = 3.141592653589793115997963468544185161590576171875, A_TO_BOHR = 1.889725989_DP

        integer, intent(in) :: nirrqpt, nat, nfc2, nfc3, ne, n_events
        integer, intent(in) :: weights(n_events), scatt_events(nirrqpt)
        real(kind=DP), intent(in) :: irrqgrid(3, nirrqpt)
        real(kind=DP), intent(in) :: qgrid(3, n_events)
        real(kind=DP), intent(in) :: qe_zeu(3, 3, nat)
        real(kind=DP), intent(in) :: fc2(nfc2, 3*nat, 3*nat)
        real(kind=DP), intent(in) :: fc3(nfc3, 3*nat, 3*nat, 3*nat)
        real(kind=DP), intent(in) :: r2_2(3, nfc2)
        real(kind=DP), intent(in) :: r3_2(3, nfc3), r3_3(3, nfc3)
        real(kind=DP), intent(in) :: rprim(3, 3), dielectric_tensor(3,3)
        real(kind=DP), intent(in) :: pos(3, nat)
        real(kind=DP), intent(in) :: masses(nat), energies(ne)
        real(kind=DP), intent(in) :: smear(3*nat, nirrqpt), smear_id(3*nat, nirrqpt)
        real(kind=DP), intent(in) :: T, qe_alat
        logical, intent(in) :: gaussian, classical, long_range
        complex(kind=DP), dimension(nirrqpt, 3*nat), intent(out) :: selfengs

        integer :: iqpt, i, jqpt, tot_qpt, prev_events, nthreads
        real(kind=DP), dimension(3) :: qpt, qe_q
        real(kind=DP), dimension(3,3) :: kprim, qe_bg
        real(kind=DP), dimension(3,nat) :: qe_tau
        real(kind=DP), dimension(3*nat) :: w2_q, w_q, tau, omega
        real(kind=DP) :: qe_omega 
        complex(kind=DP), allocatable, dimension(:, :) :: self_energy
        complex(kind=DP), dimension(3*nat,3*nat) :: pols_q, d2_q
        real(kind=DP), allocatable, dimension(:,:) :: curr_grid
        integer, allocatable, dimension(:) :: curr_w
        logical :: is_q_gamma, w_neg_freqs, parallelize


        selfengs(:,:) = complex(0.0_DP,0.0_DP)
        kprim = transpose(inv(rprim))
        nthreads = omp_get_max_threads()
        print*, 'Maximum number of threads available: ', nthreads

        parallelize = .True.
        if(nirrqpt <= nthreads) then
                parallelize = .False.
        endif
!        print*, 'Got parallelize'
        qe_tau = pos * A_TO_BOHR / qe_alat
        qe_bg = inv(rprim)*qe_alat / (A_TO_BOHR)
        qe_omega = abs(dot_product(cross(rprim(1,:), rprim(2,:)) , rprim(3,:))*A_TO_BOHR**3)

        !$OMP PARALLEL DO IF(parallelize) DEFAULT(NONE) &
        !$OMP PRIVATE(iqpt, w_neg_freqs, qpt, qe_q, w2_q, pols_q, d2_q, is_q_gamma, self_energy, &
        !$OMP curr_grid, w_q, curr_w, prev_events, tot_qpt, tau, omega) &
        !$OMP SHARED(nirrqpt, nfc2, nat, qe_zeu, fc2, r2_2, masses, kprim, dielectric_tensor, qe_bg, scatt_events, &
        !$OMP nfc3, ne, fc3, r3_2, r3_3, pos, qe_tau, smear, T, qe_alat, qe_omega, energies, parallelize, &
        !$OMP smear_id, selfengs, irrqgrid, qgrid, weights, gaussian, classical, long_range)
        do iqpt = 1, nirrqpt
            allocate(self_energy(ne, 3*nat))
!            print*, iqpt
            w_neg_freqs = .False.
            print*, 'Calculating ', iqpt, ' point in the irreducible zone out of ', nirrqpt, '!'
            qpt = irrqgrid(:, iqpt) 
            qe_q = qpt*qe_alat/A_TO_BOHR
            !call interpolate_fc2(nfc2, nat, fc2, r2_2, masses, pos, qpt, w2_q, pols_q, d2_q)
            call interpolate_fc2(nfc2, nat, fc2, qe_zeu, dielectric_tensor, qe_bg, r2_2, masses, pos, qe_tau, &
                               qpt, qe_q, qe_omega, qe_alat, long_range, w2_q, pols_q, d2_q)
            call check_if_gamma(nat, qpt, kprim, w2_q, is_q_gamma)

            if(any(w2_q < 0.0_DP)) then
                print*, 'Negative eigenvalue of dynamical matrix!'
                w_neg_freqs = .True.
            endif
!            print*, 'Interpolate frequency'
            if(.not. w_neg_freqs) then
                w_q = sqrt(w2_q)
                self_energy(:,:) = complex(0.0_DP, 0.0_DP)
                allocate(curr_grid(3, scatt_events(iqpt)))
                allocate(curr_w(scatt_events(iqpt)))
                if(iqpt > 1) then
                    prev_events = sum(scatt_events(1:iqpt-1))
                else
                    prev_events = 0
                endif
                do jqpt = 1, scatt_events(iqpt)
                    curr_grid(:,jqpt) = qgrid(:,prev_events + jqpt)
                    curr_w(jqpt) = weights(prev_events + jqpt)
                enddo
!                print*, 'Got grids'
                call calculate_self_energy_P(w_q, qpt, pols_q, is_q_gamma, scatt_events(iqpt), nat, nfc2, &
                    nfc3, ne, curr_grid, curr_w, qe_zeu, fc2, fc3, r2_2, r3_2, r3_3, pos, kprim, &
                    dielectric_tensor, masses, smear(:,iqpt), T, qe_alat, &
                    energies, .not. parallelize, gaussian, classical, long_range, self_energy) 
                deallocate(curr_grid)
                tot_qpt = sum(curr_w)
                deallocate(curr_w)
                self_energy = self_energy/dble(tot_qpt)
                if(any(self_energy .ne. self_energy)) then
                        print*, 'NaN in self_energy'
                endif
                if(gaussian) then
                        call calculate_real_part_via_Kramers_Kronig(ne, 3*nat, self_energy, energies, w_q)
                        if(any(self_energy .ne. self_energy)) then
                                print*, 'NaN in Kramers Kronig'
                        endif
                endif
                tau(:) = 0.0_DP
                omega(:) = 0.0_DP 
                call solve_selfconsistent_equation(ne, 3*nat, w_q, self_energy, energies, tau, omega)

                do i = 1, 3*nat
                    if(w_q(i) .ne. 0.0_DP) then
                        selfengs(iqpt, i) = complex(omega(i), tau(i))
                    else
                        selfengs(iqpt, i) = complex(0.0_DP, 0.0_DP)
                    endif
                enddo
            else
                selfengs(iqpt, :) = complex(0.0_DP, 0.0_DP)
            endif
            deallocate(self_energy)

        enddo
        !$OMP END PARALLEL DO

    end subroutine calculate_lifetimes_selfconsistently

    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

    subroutine solve_selfconsistent_equation(ne, nband, w_q, self_energy, energies, tau, omega)

        implicit none

        integer, parameter :: DP = selected_real_kind(14,200)
        real(kind=DP), parameter :: PI = 3.141592653589793115997963468544185161590576171875

        integer, intent(in) :: nband, ne
        real(kind=DP), intent(in) :: w_q(nband), energies(ne)
        complex(kind=DP), intent(in) :: self_energy(ne, nband)
        real(kind=DP), intent(inout) :: tau(nband), omega(nband)

        integer :: iband, ie, ie0
        real(kind=DP) :: curr_freq, prev_freq, d_freq, den, rew, imw

        den = energies(2) - energies(1) 
        do iband = 1, nband
                if(w_q(iband) > 0.0_DP) then
                        curr_freq = w_q(iband)
                        d_freq = curr_freq
                        do while(d_freq > den)
                                prev_freq = curr_freq
                                do ie = 2, ne
                                        if(curr_freq - energies(ie) < 0.0_DP .and. curr_freq - energies(ie-1) > 0.0_DP) then
                                                ie0 = ie
                                                EXIT
                                        endif
                                enddo
                                rew = dble(self_energy(ie0-1, iband)) + (curr_freq - energies(ie-1))*&
                                        (dble(self_energy(ie0,iband)) - dble(self_energy(ie0-1, iband)))/den
                                if(w_q(iband)**2 + rew > 0.0_DP) then 
                                        curr_freq = sqrt(w_q(iband)**2 + rew)
                                else
                                        curr_freq = 0.0_DP
                                        EXIT
                                endif
                                d_freq = curr_freq - prev_freq
                                if(curr_freq .ne. curr_freq) then
                                        print*, 'NaN in selfconsistent procedure!'
                                        print*, ie0, self_energy(ie0-1, iband), self_energy(ie0, iband), rew, w_q(iband)**2
                                        STOP
                                endif
                        enddo
                        omega(iband) = curr_freq
                        if(curr_freq > 0.0_DP) then
                                do ie = 2, ne
                                        if(omega(iband) - energies(ie) < 0.0_DP .and. omega(iband) - energies(ie-1) > 0.0_DP) then
                                                ie0 = ie
                                                EXIT
                                        endif
                                enddo
                                imw = aimag(self_energy(ie0-1, iband)) + (omega(iband) - energies(ie-1))*&
                                        (aimag(self_energy(ie0,iband)) - aimag(self_energy(ie0-1, iband)))/den
                                tau(iband) = imw/2.0_DP/w_q(iband)
                        else
                                omega(iband) = 0.0_DP
                                tau(iband) = 0.0_DP
                        endif
                else
                        omega(iband) = 0.0_DP
                        tau(iband) = 0.0_DP
                endif
        enddo

    end subroutine solve_selfconsistent_equation

    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

    subroutine calculate_correlation_function(energies, w_q, self_energy, nat, ne, lineshape)

        implicit none

        integer, parameter :: DP = selected_real_kind(14,200)
        real(kind=DP), parameter :: PI = 3.141592653589793115997963468544185161590576171875

        integer, intent(in) :: nat, ne
        real(kind=DP), intent(in) :: w_q(3*nat), energies(ne)
        complex(kind=DP), intent(in) :: self_energy(ne, 3*nat)
        real(kind=DP), intent(inout) :: lineshape(ne, 3*nat)

        integer :: iband, ie
        real(kind = DP) :: a, b

        lineshape(:,:) = 0.0_DP
        do iband = 1, 3*nat
                if(w_q(iband) .gt. 0.0_DP) then
                        do ie = 2, ne
                                a = (energies(ie)**2 - dble(self_energy(ie, iband)) - w_q(iband)**2)
                                b = aimag(self_energy(ie, iband))
                                if(a .ne. 0.0_DP .and. b .ne. 0.0_DP) then
                                        lineshape(ie, iband) = -aimag(self_energy(ie, iband))/(a**2+b**2)
                                endif 
                        enddo
                        lineshape(:, iband) = lineshape(:, iband)*w_q(iband)/PI
                endif
        enddo 

    end subroutine calculate_correlation_function

    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

    subroutine calculate_lifetimes_perturbative(irrqgrid, qgrid, weights, scatt_events, qe_zeu, fc2, r2_2, &
                    fc3, r3_2, r3_3, rprim, dielectric_tensor, pos, masses, smear, T, qe_alat, gaussian, &
                    classical, long_range, nirrqpt, nat, nfc2, nfc3, n_events, self_energies)

        use omp_lib
        implicit none

        integer, parameter :: DP = selected_real_kind(14,200)
        real(kind=DP), parameter :: PI = 3.141592653589793115997963468544185161590576171875, A_TO_BOHR = 1.889725989_DP

        integer, intent(in) :: nirrqpt, nat, nfc2, nfc3, n_events
        integer, intent(in) :: weights(n_events), scatt_events(nirrqpt)
        real(kind=DP), intent(in) :: irrqgrid(3, nirrqpt)
        real(kind=DP), intent(in) :: qgrid(3, n_events)
        real(kind=DP), intent(in) :: qe_zeu(3, 3, nat)
        real(kind=DP), intent(in) :: fc2(nfc2, 3*nat, 3*nat)
        real(kind=DP), intent(in) :: fc3(nfc3, 3*nat, 3*nat, 3*nat)
        real(kind=DP), intent(in) :: r2_2(3, nfc2)
        real(kind=DP), intent(in) :: r3_2(3, nfc3), r3_3(3, nfc3)
        real(kind=DP), intent(in) :: rprim(3, 3), dielectric_tensor(3,3)
        real(kind=DP), intent(in) :: pos(3, nat)
        real(kind=DP), intent(in) :: masses(nat)
        real(kind=DP), intent(in) :: smear(3*nat, nirrqpt)
        real(kind=DP), intent(in) :: T, qe_alat
        logical, intent(in) :: gaussian, classical, long_range
        complex(kind=DP), dimension(nirrqpt, 3*nat), intent(out) :: self_energies

        integer :: iqpt, i, tot_qpt, jqpt, prev_events, nthreads
        real(kind=DP), dimension(3) :: qpt, qe_q
        real(kind=DP), dimension(3,3) :: kprim, qe_bg
        real(kind=DP), dimension(3,nat) :: qe_tau
        real(kind=DP), dimension(3*nat) :: w2_q, w_q
        complex(kind=DP), dimension(3*nat, 3*nat) :: self_energy
        real(kind=DP) :: qe_omega 
!        complex(kind=DP), allocatable, dimension(:,:) :: self_energy
        complex(kind=DP), dimension(3*nat,3*nat) :: pols_q, d2_q
        real(kind=DP), allocatable, dimension(:,:) :: curr_grid
        integer, allocatable, dimension(:) :: curr_w
        logical :: is_q_gamma, w_neg_freqs, parallelize

        self_energies(:,:) = 0.0_DP
        kprim = transpose(inv(rprim))
        print*, 'Calculating phonon lifetimes in perturbative regime!'

        nthreads = omp_get_max_threads()
        print*, 'Maximum number of threads available: ', nthreads

        parallelize = .True.
        if(nirrqpt <= nthreads) then
                parallelize = .False.
        endif
        qe_tau = pos * A_TO_BOHR / qe_alat
        qe_bg = inv(rprim)*qe_alat / (A_TO_BOHR)
        qe_omega = abs(dot_product(cross(rprim(1,:), rprim(2,:)) , rprim(3,:))*A_TO_BOHR**3)
        
        !$OMP PARALLEL DO IF(parallelize) &
        !$OMP DEFAULT(SHARED) &
        !$OMP PRIVATE(iqpt, w_neg_freqs, qpt, qe_q, w2_q, pols_q, d2_q, is_q_gamma, self_energy, &
        !$OMP curr_grid, w_q, curr_w, prev_events, tot_qpt)
        do iqpt = 1, nirrqpt

            w_neg_freqs = .False.
            print*, 'Calculating ', iqpt, ' point in the irreducible zone out of ', nirrqpt, '!'
            qpt = irrqgrid(:, iqpt) 
            qe_q = qpt*qe_alat/A_TO_BOHR
            !call interpolate_fc2(nfc2, nat, fc2, r2_2, masses, pos, qpt, w2_q, pols_q, d2_q)
            call interpolate_fc2(nfc2, nat, fc2, qe_zeu, dielectric_tensor, qe_bg, r2_2, masses, pos, qe_tau, &
                               qpt, qe_q, qe_omega, qe_alat, long_range, w2_q, pols_q, d2_q)
            call check_if_gamma(nat, qpt, kprim, w2_q, is_q_gamma)
            if(any(w2_q < 0.0_DP)) then
                print*, 'Negative eigenvalue of dynamical matrix! Exit!'
                w_neg_freqs = .True.
            endif
            
            if(.not. w_neg_freqs) then 
                w_q = sqrt(w2_q)
                self_energy(:,:) = complex(0.0_DP, 0.0_DP)
                allocate(curr_grid(3, scatt_events(iqpt)))
                allocate(curr_w(scatt_events(iqpt)))
                if(iqpt > 1) then
                    prev_events = sum(scatt_events(1:iqpt-1))
                else
                    prev_events = 0
                endif
                do jqpt = 1, scatt_events(iqpt)
                    curr_grid(:,jqpt) = qgrid(:,prev_events + jqpt)
                    curr_w(jqpt) = weights(prev_events + jqpt)
                enddo
                call calculate_self_energy_P(w_q, qpt, pols_q, is_q_gamma, scatt_events(iqpt), nat, nfc2, &
                            nfc3, 3*nat, curr_grid, curr_w, qe_zeu, fc2, fc3, r2_2, r3_2, r3_3, pos, kprim, &
                            dielectric_tensor, masses, smear(:,iqpt), T, qe_alat, w_q, .not. parallelize, &
                            gaussian, classical, long_range, self_energy) 

                deallocate(curr_grid)
                tot_qpt = sum(curr_w)
                deallocate(curr_w)
                self_energy = self_energy/dble(tot_qpt)

                do i = 1, 3*nat
                    if(w_q(i) .ne. 0.0_DP) then
                        self_energies(iqpt, i) = self_energy(i,i)/2.0_DP/w_q(i)
                    else
                        self_energies(iqpt, i) = complex(0.0_DP, 0.0_DP)
                    endif
                enddo
            else
                self_energies(iqpt, :) = complex(0.0_DP, 0.0_DP)
            endif

        enddo
        !$OMP END PARALLEL DO


    end subroutine calculate_lifetimes_perturbative

 !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

    subroutine calculate_lifetimes(irrqgrid, qgrid, weights, scatt_events, qe_zeu, fc2, r2_2, &
                    fc3, r3_2, r3_3, rprim, dielectric_tensor, pos, masses, smear, T, qe_alat, gaussian, classical, &
                    long_range, nirrqpt, nat, nfc2, nfc3, n_events, self_energies)

        use omp_lib
        implicit none

        integer, parameter :: DP = selected_real_kind(14,200)
        real(kind=DP), parameter :: PI = 3.141592653589793115997963468544185161590576171875, A_TO_BOHR = 1.889725989_DP

        integer, intent(in) :: nirrqpt, nat, nfc2, nfc3, n_events
        integer, intent(in) :: weights(n_events), scatt_events(nirrqpt)
        real(kind=DP), intent(in) :: irrqgrid(3, nirrqpt)
        real(kind=DP), intent(in) :: qgrid(3, n_events)
        real(kind=DP), intent(in) :: qe_zeu(3, 3, nat)
        real(kind=DP), intent(in) :: fc2(nfc2, 3*nat, 3*nat)
        real(kind=DP), intent(in) :: fc3(nfc3, 3*nat, 3*nat, 3*nat)
        real(kind=DP), intent(in) :: r2_2(3, nfc2)
        real(kind=DP), intent(in) :: r3_2(3, nfc3), r3_3(3, nfc3)
        real(kind=DP), intent(in) :: rprim(3, 3), dielectric_tensor(3,3)
        real(kind=DP), intent(in) :: pos(3, nat)
        real(kind=DP), intent(in) :: masses(nat)
        real(kind=DP), intent(in) :: smear(3*nat, nirrqpt)
        real(kind=DP), intent(in) :: T, qe_alat
        logical, intent(in) :: gaussian, classical, long_range
        complex(kind=DP), dimension(nirrqpt, 3*nat), intent(out) :: self_energies

        integer :: iqpt, i, prev_events, jqpt, tot_qpt, nthreads
        real(kind=DP) :: start_time, curr_time
        real(kind=DP), dimension(3) :: qpt, qe_q
        real(kind=DP), dimension(3,3) :: kprim, qe_bg
        real(kind=DP), dimension(3,nat) :: qe_tau
        real(kind=DP), dimension(3*nat) :: w2_q, w_q
        complex(kind=DP), dimension(3*nat) :: self_energy
        real(kind=DP) :: qe_omega 
        complex(kind=DP), dimension(3*nat,3*nat) :: pols_q, d2_q
        real(kind=DP), allocatable, dimension(:,:) :: curr_grid
        integer, allocatable, dimension(:) :: curr_w
        logical :: is_q_gamma, w_neg_freqs, parallelize

        call cpu_time(start_time)
        self_energies(:,:) = complex(0.0_DP, 0.0_DP)
        kprim = transpose(inv(rprim))
        print*, 'Calculating phonon lifetimes in Lorentzian regime!'

        nthreads = omp_get_max_threads()
        print*, 'Maximum number of threads available: ', nthreads

        parallelize = .True.
        if(nirrqpt <= nthreads) then
                parallelize = .False.
        endif
        qe_tau = pos * A_TO_BOHR / qe_alat
        qe_bg = inv(rprim)*qe_alat / (A_TO_BOHR)
        qe_omega = abs(dot_product(cross(rprim(1,:), rprim(2,:)) , rprim(3,:))*A_TO_BOHR**3)

        !$OMP PARALLEL DO IF(parallelize) &
        !$OMP DEFAULT(SHARED) &
        !$OMP PRIVATE(iqpt, w_neg_freqs, qpt, qe_q, w2_q, pols_q, d2_q, is_q_gamma, self_energy, &
        !$OMP curr_grid, w_q, curr_w, prev_events, tot_qpt)
        do iqpt = 1, nirrqpt
            
            w_neg_freqs = .False.
            print*, 'Calculating ', iqpt, ' point in the irreducible zone out of ', nirrqpt, '!'
            !call cpu_time(curr_time)
            !print*, 'Since start: ', curr_time - start_time, ' seconds!'
            qpt = irrqgrid(:, iqpt) 
            qe_q = qpt*qe_alat/A_TO_BOHR
            !call interpolate_fc2(nfc2, nat, fc2, r2_2, masses, pos, qpt, w2_q, pols_q, d2_q)
            call interpolate_fc2(nfc2, nat, fc2, qe_zeu, dielectric_tensor, qe_bg, r2_2, masses, pos, qe_tau, &
                               qpt, qe_q, qe_omega, qe_alat, long_range, w2_q, pols_q, d2_q)
            call check_if_gamma(nat, qpt, kprim, w2_q, is_q_gamma)
 !           print*, 'Got frequencies'
            if(any(w2_q < 0.0_DP)) then
                print*, 'Negative eigenvalue of dynamical matrix! Exit!'
                w_neg_freqs = .True.
            endif

            if(.not. w_neg_freqs) then
                w_q = sqrt(w2_q)
                self_energy(:) = complex(0.0_DP, 0.0_DP)
                allocate(curr_grid(3, scatt_events(iqpt)))
                allocate(curr_w(scatt_events(iqpt)))
                if(iqpt > 1) then
                    prev_events = sum(scatt_events(1:iqpt-1))
                else
                    prev_events = 0
                endif
                do jqpt = 1, scatt_events(iqpt)
                    curr_grid(:,jqpt) = qgrid(:,prev_events + jqpt)
                    curr_w(jqpt) = weights(prev_events + jqpt)
                enddo
                call calculate_self_energy_LA(w_q, qpt, pols_q, is_q_gamma, scatt_events(iqpt), nat, nfc2, nfc3, curr_grid, &
                            curr_w, qe_zeu, fc2, fc3, r2_2, r3_2, r3_3, pos, kprim, dielectric_tensor, &
                            masses, smear(:,iqpt), T, qe_alat, .not. parallelize, gaussian, classical, long_range, self_energy)

                deallocate(curr_grid)
                tot_qpt = sum(curr_w)
                deallocate(curr_w)
                self_energy = self_energy/dble(tot_qpt)
            else
                self_energy(:) = complex(0.0_DP, 0.0_DP)
            endif

            do i = 1, 3*nat
                if(w_q(i) .ne. 0.0_DP) then
                        self_energies(iqpt, i) = sqrt(w_q(i)**2 + self_energy(i))
                else
                        self_energies(iqpt, i) = complex(0.0_DP, 0.0_DP)
                endif
            enddo

        enddo
        !$OMP END PARALLEL DO
                            
                            
    end subroutine calculate_lifetimes

 !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

    subroutine calculate_self_energy_LA(w_q, qpt, pols_q, is_q_gamma, nqpt, nat, nfc2, nfc3, &
                    qgrid, weights, qe_zeu, fc2, fc3, &
                    r2_2, r3_2, r3_3, pos, kprim, dielectric_tensor, masses, smear, T, qe_alat, &
                    parallelize, gaussian, classical, long_range, self_energy)

        use omp_lib
        use third_order_cond

        implicit none
        integer, parameter :: DP = selected_real_kind(14,200)
        real(kind=DP), parameter :: PI = 3.141592653589793115997963468544185161590576171875, A_TO_BOHR = 1.889725989_DP

        integer, intent(in) :: nqpt, nat, nfc2, nfc3
        integer, intent(in) :: weights(nqpt)
        real(kind=DP), intent(in) :: w_q(3*nat), qpt(3), qgrid(3,nqpt)
        real(kind=DP), intent(in) :: fc2(nfc2, 3*nat, 3*nat), kprim(3,3), dielectric_tensor(3,3)
        real(kind=DP), intent(in) :: fc3(nfc3, 3*nat, 3*nat, 3*nat), qe_zeu(3,3,nat)
        real(kind=DP), intent(in) :: r2_2(3, nfc2), pos(3, nat)
        real(kind=DP), intent(in) :: r3_2(3, nfc3), r3_3(3, nfc3)
        real(kind=DP), intent(in) :: masses(nat)
        real(kind=DP), intent(in) :: smear(3*nat)
        real(kind=DP), intent(in) :: T, qe_alat
        complex(kind=DP), intent(in) :: pols_q(3*nat,3*nat)
        logical, intent(in) :: is_q_gamma, parallelize, gaussian, classical, long_range
        complex(kind=DP), intent(out) :: self_energy(3*nat)

        integer :: jqpt, iat, jat, kat, i, j, k, i1, j1, k1
        real(kind=DP), dimension(3) :: kpt, mkpt, mkpt_r, qe_kpt, qe_mkpt
        real(kind=DP), dimension(3*nat) :: w2_k, w2_mk_mq
        real(kind=DP), dimension(3*nat) :: w_k, w_mk_mq
        real(kind=DP), allocatable, dimension(:,:,:) :: mass_array
        real(kind=DP), dimension(3*nat, 3) :: freqs_array
        real(kind=DP), dimension(3, 3*nat) :: qe_tau
        real(kind=DP), dimension(3, 3) :: ikprim, rprim, qe_bg
        real(kind=DP) :: qe_omega 
        complex(kind=DP), dimension(3*nat) :: selfnrg
        complex(kind=DP), dimension(3*nat,3*nat) :: pols_k, pols_mk_mq, pols_k2, pols_mk_mq2
!        complex(kind=DP), dimension(3*nat, 3*nat, 3*nat) :: ifc3, d3, d3_pols
        complex(kind=DP), allocatable, dimension(:, :, :) :: ifc3, d3, d3_pols, intermediate
        logical :: is_k_gamma, is_mk_mq_gamma, is_k_neg, is_mk_mq_neg
        logical, dimension(3) :: if_gammas

        ikprim = inv(kprim)
        rprim = transpose(inv(kprim))
        self_energy = complex(0.0_DP, 0.0_DP)
        allocate(mass_array(3*nat, 3*nat, 3*nat))
        do iat = 1, nat
            do jat = 1, nat
                do kat = 1, nat
                    mass_array(3*(kat - 1) + 1:3*kat, 3*(jat - 1) + 1:3*jat, 3*(iat - 1) + 1:3*iat) = &
                    1.0_DP/sqrt(masses(iat)*masses(jat)*masses(kat))
                enddo
            enddo
        enddo
        qe_tau = pos * A_TO_BOHR / qe_alat
        qe_bg = inv(rprim)*qe_alat / (A_TO_BOHR)
        qe_omega = abs(dot_product(cross(rprim(1,:), rprim(2,:)) , rprim(3,:))*A_TO_BOHR**3)

  !      print*, 'Calculating self-energy!'
        !$OMP PARALLEL DO IF(parallelize) DEFAULT(NONE) &
        !$OMP PRIVATE(i,j,k,i1,j1,k1, jqpt, ifc3, d3, d3_pols, kpt, qe_kpt, mkpt, qe_mkpt, mkpt_r, is_k_gamma, is_mk_mq_gamma, &
        !$OMP w2_k, w2_mk_mq, w_k, w_mk_mq, pols_k, pols_mk_mq, pols_k2, pols_mk_mq2, iat, jat, kat, freqs_array, if_gammas, &
        !$OMP is_k_neg, is_mk_mq_neg, selfnrg, intermediate) &
        !$OMP SHARED(nqpt, nat, fc3, r3_2, r3_3, pos, nfc2, nfc3, masses, qe_zeu, fc2, smear, T, qe_alat, weights, qgrid, qpt, &
        !$OMP kprim, dielectric_tensor, is_q_gamma, qe_omega, qe_bg, qe_tau, &
        !$OMP r2_2, w_q, pols_q, mass_array, gaussian, classical, long_range, ikprim) &
        !$OMP REDUCTION(+:self_energy)
        do jqpt = 1, nqpt
!            print*, jqpt
            allocate(ifc3(3*nat, 3*nat, 3*nat), d3(3*nat, 3*nat, 3*nat), d3_pols(3*nat, 3*nat, 3*nat))
            allocate(intermediate(3*nat, 3*nat, 3*nat))
            is_k_neg = .False.
            is_mk_mq_neg = .False.
            ifc3(:,:,:) = complex(0.0_DP, 0.0_DP) 
            d3(:,:,:) = complex(0.0_DP, 0.0_DP) 
            d3_pols(:,:,:) = complex(0.0_DP, 0.0_DP) 

            kpt = qgrid(:, jqpt)
            qe_kpt = kpt*qe_alat/A_TO_BOHR
            mkpt = -1.0_DP*qpt - kpt
            do i = 1, 3
                mkpt_r(i) = dot_product(mkpt, ikprim(:,i))
                if(mkpt_r(i) > 0.50_DP) then
                        mkpt_r(i) = mkpt_r(i) - 1.0_DP
                else if(mkpt_r(i) < -0.50_DP) then
                        mkpt_r(i) = mkpt_r(i) + 1.0_DP
                endif
            enddo
            do i = 1, 3
                mkpt(i) = dot_product(mkpt_r, kprim(:,i))
            enddo
            qe_mkpt = mkpt*qe_alat/A_TO_BOHR
            call interpol_v2(fc3, r3_2, r3_3,pos, kpt, mkpt, ifc3, nfc3, nat)
           ! call interpol_v3(fc3, pos, r3_2, r3_3, qpt, kpt, mkpt, ifc3, nfc3, nat)
            !call interpolate_fc2(nfc2, nat, fc2, r2_2, masses, pos, kpt, w2_k, pols_k, pols_k2)
            call interpolate_fc2(nfc2, nat, fc2, qe_zeu, dielectric_tensor, qe_bg, r2_2, masses, pos, qe_tau, &
                               kpt, qe_kpt, qe_omega, qe_alat, long_range, w2_k, pols_k, pols_k2)
            !call interpolate_fc2(nfc2, nat, fc2, r2_2, masses, pos, mkpt, w2_mk_mq, pols_mk_mq, pols_mk_mq2)
            call interpolate_fc2(nfc2, nat, fc2, qe_zeu, dielectric_tensor, qe_bg, r2_2, masses, pos, qe_tau, &
                               mkpt, qe_mkpt, qe_omega, qe_alat, long_range, w2_mk_mq, pols_mk_mq, pols_mk_mq2)
    
            call check_if_gamma(nat, kpt, kprim, w2_k, is_k_gamma)
            call check_if_gamma(nat, mkpt, kprim, w2_mk_mq, is_mk_mq_gamma)
            if(any(w2_k < 0.0_DP)) then
                print*, 'Negative eigenvalue of dynamical matrix! Exit!'
                is_k_neg = .True.
            endif
            if(any(w2_mk_mq < 0.0_DP)) then
                print*, 'Negative eigenvalue of dynamical matrix! Exit!'
                is_mk_mq_neg = .True.
            endif

            if(.not. is_k_neg .and. .not. is_mk_mq_neg) then
            w_k = sqrt(w2_k)
            w_mk_mq = sqrt(w2_mk_mq)

            d3 = ifc3*mass_array

            !do i = 1, 3*nat
            !do i1 = 1, 3*nat
            !    d3_pols(:,:,i) = d3_pols(:,:,i) + &
            !        matmul(matmul(transpose(pols_q), d3(:,:,i1)), pols_k)*pols_mk_mq(i1,i)
            !enddo
            !enddo
            intermediate = complex(0.0_DP, 0.0_DP)
            do i=1,3*nat
                intermediate(:,:,i) = matmul(matmul(transpose(pols_q), d3(:,:,i)), pols_k)
            enddo

            do i1=1,3*nat
                d3_pols(:,i1,:) = matmul(intermediate(:,i1,:), pols_mk_mq)
            enddo

            freqs_array(:, 1) = w_q
            freqs_array(:, 2) = w_k
            freqs_array(:, 3) = w_mk_mq

            if_gammas(1) = is_q_gamma
            if_gammas(2) = is_k_gamma
            if_gammas(3) = is_mk_mq_gamma
      
            selfnrg = complex(0.0_DP,0.0_DP)
            call compute_perturb_selfnrg_single(smear,T, &
                freqs_array, if_gammas, d3_pols, 3*nat, gaussian, classical, selfnrg)
            self_energy = self_energy + selfnrg*dble(weights(jqpt))
            endif
            deallocate(ifc3, d3, d3_pols, intermediate)
        enddo
        !$OMP END PARALLEL DO

    end subroutine calculate_self_energy_LA

 !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

    subroutine calculate_self_energy_P(w_q, qpt, pols_q, is_q_gamma, nqpt, nat, nfc2, nfc3, ne, qgrid, &
                    weights, qe_zeu, fc2, fc3, r2_2, r3_2, r3_3, pos, kprim, dielectric_tensor, masses, &
                    smear, T, qe_alat, energies, parallelize, gaussian, classical, long_range, self_energy)

        use omp_lib
        use third_order_cond

        implicit none
        integer, parameter :: DP = selected_real_kind(14,200)
        real(kind=DP), parameter :: PI = 3.141592653589793115997963468544185161590576171875, A_TO_BOHR = 1.889725989_DP

        integer, intent(in) :: nqpt, nat, nfc2, nfc3, ne
        integer, intent(in) :: weights(nqpt)
        real(kind=DP), intent(in) :: w_q(3*nat), qpt(3), qgrid(3,nqpt)
        real(kind=DP), intent(in) :: fc2(nfc2, 3*nat, 3*nat), kprim(3,3), dielectric_tensor(3,3)
        real(kind=DP), intent(in) :: fc3(nfc3, 3*nat, 3*nat, 3*nat), qe_zeu(3,3,nat)
        real(kind=DP), intent(in) :: r2_2(3, nfc2), pos(3, nat)
        real(kind=DP), intent(in) :: r3_2(3, nfc3), r3_3(3, nfc3)
        real(kind=DP), intent(in) :: masses(nat)
        real(kind=DP), intent(in) :: smear(3*nat), energies(ne)
        real(kind=DP), intent(in) :: T, qe_alat
        complex(kind=DP), intent(in) :: pols_q(3*nat,3*nat)
        logical, intent(in) :: is_q_gamma, parallelize, gaussian, classical, long_range
        complex(kind=DP), intent(out) :: self_energy(ne, 3*nat)

        integer :: jqpt, iat, jat, kat, i, j, k, i1, j1, k1
!        real(kind=DP), dimension(3) :: kpt, mkpt
!        real(kind=DP), dimension(3*nat) :: w2_k, w2_mk_mq
!        real(kind=DP), dimension(3*nat) :: w_k, w_mk_mq
        real(kind=DP), allocatable, dimension(:) :: kpt, mkpt, w2_k, w2_mk_mq, w_k, w_mk_mq
        real(kind=DP), allocatable, dimension(:) :: qe_kpt, qe_mkpt
!        real(kind=DP), dimension(3*nat, 3) :: freqs_array
        real(kind=DP), allocatable, dimension(:, :) :: freqs_array, rprim, qe_tau, qe_bg
        real(kind=DP), allocatable, dimension(:, :, :) :: mass_array
        !complex(kind=DP), dimension(ne, 3*nat) :: selfnrg
        complex(kind=DP), allocatable, dimension(:, :) :: selfnrg
        complex(kind=DP), allocatable,dimension(:,:) :: pols_k, pols_mk_mq, pols_k2, pols_mk_mq2
        complex(kind=DP), allocatable, dimension(:, :, :) :: ifc3, d3, d3_pols, intermediate
        real(kind=DP) :: qe_omega 
        logical :: is_k_gamma, is_mk_mq_gamma, is_k_neg, is_mk_mq_neg
        logical, dimension(3) :: if_gammas


        allocate(rprim(3,3), qe_tau(3, nat), qe_bg(3,3))
        rprim = transpose(inv(kprim))
!        allocate(self_energy(ne, 3*nat))
        self_energy = complex(0.0_DP, 0.0_DP)
!        allocate(mass_array(3*nat, 3*nat, 3*nat))
!        do iat = 1, nat
!            do jat = 1, nat
!                do kat = 1, nat
!                    mass_array(3*(kat - 1) + 1:3*kat, 3*(jat - 1) + 1:3*jat, 3*(iat - 1) + 1:3*iat) = &
!                    1.0_DP/sqrt(masses(iat)*masses(jat)*masses(kat))
!                enddo
!            enddo
!        enddo
        qe_tau = pos * A_TO_BOHR / qe_alat
        qe_bg = inv(rprim)*qe_alat / ( A_TO_BOHR)
        qe_omega = abs(dot_product(cross(rprim(1,:), rprim(2,:)) , rprim(3,:))*A_TO_BOHR**3)

!        print*, 'Starting with self energy!'
        !$OMP PARALLEL DO IF(parallelize) &
        !$OMP DEFAULT(NONE) &
        !$OMP PRIVATE(jqpt, ifc3, d3, d3_pols, kpt, mkpt, qe_kpt, qe_mkpt, w2_k, pols_k, pols_k2, &
        !$OMP w2_mk_mq, pols_mk_mq, pols_mk_mq2, is_k_gamma, is_mk_mq_gamma, intermediate, &
        !$OMP is_k_neg, is_mk_mq_neg, w_k, w_mk_mq, i,j,k,i1,j1,k1,iat,jat,kat, freqs_array, if_gammas, selfnrg) &
        !$OMP SHARED(nqpt, qgrid, fc3, r3_2, r3_3, pos, qe_tau, qpt, nfc3, nat, nfc2, qe_zeu, fc2, r2_2, masses, &
        !$OMP is_q_gamma, smear, T, qe_alat, qe_omega, energies, ne, w_q, pols_q,weights, kprim, &
        !$OMP dielectric_tensor, qe_bg, gaussian, classical, long_range) &
        !$OMP REDUCTION(+:self_energy)
        do jqpt = 1, nqpt
!            print*, jqpt
            allocate(ifc3(3*nat, 3*nat, 3*nat), d3(3*nat, 3*nat, 3*nat), d3_pols(3*nat, 3*nat, 3*nat))
            allocate(intermediate(3*nat, 3*nat, 3*nat))
            allocate(selfnrg(ne, 3*nat))
            allocate(pols_k(3*nat,3*nat), pols_mk_mq(3*nat,3*nat))
            allocate(pols_k2(3*nat,3*nat), pols_mk_mq2(3*nat,3*nat))
            allocate(kpt(3), mkpt(3),qe_kpt(3), qe_mkpt(3))
            allocate(w2_k(3*nat), w2_mk_mq(3*nat), w_k(3*nat), w_mk_mq(3*nat))
            allocate(freqs_array(3*nat, 3))
            is_k_neg = .False.
            is_mk_mq_neg = .False.
            ifc3(:,:,:) = complex(0.0_DP, 0.0_DP) 
            d3(:,:,:) = complex(0.0_DP, 0.0_DP) 
            d3_pols(:,:,:) = complex(0.0_DP, 0.0_DP) 

            kpt = qgrid(:, jqpt)
            qe_kpt = kpt*qe_alat/A_TO_BOHR
            mkpt = -1.0_DP*qpt - kpt
            qe_mkpt = mkpt*qe_alat/A_TO_BOHR
            call interpol_v2(fc3, r3_2, r3_3, pos, kpt, mkpt, ifc3, nfc3, nat)
            !call interpolate_fc2(nfc2, nat, fc2, r2_2, masses, pos, kpt, w2_k, pols_k, pols_k2)
            call interpolate_fc2(nfc2, nat, fc2, qe_zeu, dielectric_tensor, qe_bg, r2_2, masses, pos, qe_tau, &
                               kpt, qe_kpt, qe_omega, qe_alat,long_range, w2_k, pols_k, pols_k2)
            !call interpolate_fc2(nfc2, nat, fc2, r2_2, masses, pos, mkpt, w2_mk_mq, pols_mk_mq, pols_mk_mq2)
            call interpolate_fc2(nfc2, nat, fc2, qe_zeu, dielectric_tensor, qe_bg, r2_2, masses, pos, qe_tau, &
                               mkpt, qe_mkpt, qe_omega, qe_alat, long_range, w2_mk_mq, pols_mk_mq, pols_mk_mq2)
    
            call check_if_gamma(nat, kpt, kprim, w2_k, is_k_gamma)
            call check_if_gamma(nat, mkpt, kprim, w2_mk_mq, is_mk_mq_gamma)
            if(any(w2_k < 0.0_DP) .and. .not. is_k_gamma) then
                print*, 'Negative eigenvalue of dynamical matrix! Exit!', is_k_gamma
                print*, kpt
                print*, vec_dot_mat(qpt, inv(kprim))
                print*, vec_dot_mat(kpt, inv(kprim))
                print*, vec_dot_mat(mkpt, inv(kprim))
                print*, kprim
                print*, w2_k
                is_k_neg = .True.
            endif
            if(any(w2_mk_mq < 0.0_DP) .and. .not. is_mk_mq_gamma) then
                print*, 'Negative eigenvalue of dynamical matrix! Exit!', is_mk_mq_gamma, 'mk_mq_gamma'
                print*, mkpt
                print*, vec_dot_mat(qpt, inv(kprim))
                print*, vec_dot_mat(kpt, inv(kprim))
                print*, vec_dot_mat(mkpt, inv(kprim))
                print*, kprim
                print*, w2_mk_mq
                is_mk_mq_neg = .True.
            endif
!            print*, 'Calculated frequencies! '
            if(.not. is_k_neg .and. .not. is_mk_mq_neg) then
            w_k = sqrt(w2_k)
            w_mk_mq = sqrt(w2_mk_mq)

            do iat = 1, nat
            do i = 1, 3
                do jat = 1, nat
                do j = 1, 3
                    do kat = 1, nat
                    do k = 1, 3
                        d3(k + 3*(kat - 1), j + 3*(jat - 1), i + 3*(iat - 1)) = &
                                       ifc3(k + 3*(kat - 1), j + 3*(jat - 1), i + 3*(iat - 1))&
                                        /sqrt(masses(iat)*masses(jat)*masses(kat))
                    enddo
                    enddo
                enddo
                enddo
            enddo
            enddo

            !do i = 1, 3*nat
            !do i1 = 1, 3*nat
            !    d3_pols(:,:,i) = d3_pols(:,:,i) + &
            !        matmul(matmul(transpose(pols_q), d3(:,:,i1)), pols_k)*pols_mk_mq(i1,i)
            !enddo
            !enddo

            intermediate = complex(0.0_DP, 0.0_DP)
            do i=1,3*nat
                intermediate(:,:,i) = matmul(matmul(transpose(pols_q), d3(:,:,i)), pols_k)
            enddo

            do i1=1,3*nat
                d3_pols(:,i1,:) = matmul(intermediate(:,i1,:), pols_mk_mq)
            enddo
              
!            print*, 'Got d3pols'

            freqs_array(:, 1) = w_q
            freqs_array(:, 2) = w_k
            freqs_array(:, 3) = w_mk_mq

            if_gammas(1) = is_q_gamma
            if_gammas(2) = is_k_gamma
            if_gammas(3) = is_mk_mq_gamma
      
            selfnrg = complex(0.0_DP,0.0_DP)
            call compute_diag_dynamic_bubble_single(energies, smear, T, freqs_array, if_gammas, &
                    d3_pols, ne, 3*nat, gaussian, classical, selfnrg)
!            print*, 'Got selfnrg!'
            self_energy = self_energy + selfnrg*dble(weights(jqpt))
            if(any(self_energy .ne. self_energy)) then
                    print*, 'NaN for jqpt', jqpt
            endif
            deallocate(ifc3, d3, d3_pols, selfnrg)
            deallocate(pols_k, pols_mk_mq, intermediate)
            deallocate(pols_k2, pols_mk_mq2)
            deallocate(kpt, mkpt, qe_kpt, qe_mkpt)
            deallocate(w2_k, w2_mk_mq, w_k, w_mk_mq)
            deallocate(freqs_array)
            else
            deallocate(ifc3, d3, d3_pols, selfnrg)
            deallocate(pols_k, pols_mk_mq)
            deallocate(pols_k2, pols_mk_mq2)
            deallocate(kpt, mkpt)
            deallocate(w2_k, w2_mk_mq, w_k, w_mk_mq)
            deallocate(freqs_array)
            endif
        enddo
        !$OMP END PARALLEL DO
!        print*, 'Finished with self energy!'
    end subroutine calculate_self_energy_P
 
    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

    subroutine calculate_self_energy_full(w_q, qpt, pols_q, is_q_gamma, nqpt, nat, nfc2, nfc3, ne, qgrid, &
                    weights, qe_zeu, fc2, fc3, r2_2, r3_2, r3_3, pos, kprim, dielectric_tensor, masses, &
                    smear, T, qe_alat, energies, parallelize, gaussian, classical, long_range, self_energy)

        use omp_lib
        use third_order_cond

        implicit none
        integer, parameter :: DP = selected_real_kind(14,200)
        real(kind=DP), parameter :: PI = 3.141592653589793115997963468544185161590576171875, A_TO_BOHR = 1.889725989_DP

        integer, intent(in) :: nqpt, nat, nfc2, nfc3, ne
        integer, intent(in) :: weights(nqpt)
        real(kind=DP), intent(in) :: w_q(3*nat), qpt(3), qgrid(3,nqpt)
        real(kind=DP), intent(in) :: fc2(nfc2, 3*nat, 3*nat), kprim(3,3), dielectric_tensor(3,3)
        real(kind=DP), intent(in) :: fc3(nfc3, 3*nat, 3*nat, 3*nat), qe_zeu(3,3,nat)
        real(kind=DP), intent(in) :: r2_2(3, nfc2), pos(3, nat)
        real(kind=DP), intent(in) :: r3_2(3, nfc3), r3_3(3, nfc3)
        real(kind=DP), intent(in) :: masses(nat)
        real(kind=DP), intent(in) :: smear(3*nat), energies(ne)
        real(kind=DP), intent(in) :: T, qe_alat
        complex(kind=DP), intent(in) :: pols_q(3*nat,3*nat)
        logical, intent(in) :: is_q_gamma, parallelize, gaussian, classical, long_range
        complex(kind=DP), intent(out) :: self_energy(ne, 3*nat, 3*nat)

        integer :: jqpt, iat, jat, kat, i, j, k, i1, j1, k1
        real(kind=DP), allocatable, dimension(:) :: kpt, mkpt, w2_k, w2_mk_mq, w_k, w_mk_mq
        real(kind=DP), allocatable, dimension(:) :: qe_kpt, qe_mkpt
        real(kind=DP), allocatable, dimension(:, :) :: freqs_array, rprim, qe_tau, qe_bg
        real(kind=DP), allocatable, dimension(:, :, :) :: mass_array
        complex(kind=DP), allocatable, dimension(:, :, :) :: selfnrg
        complex(kind=DP), allocatable,dimension(:,:) :: pols_k, pols_mk_mq, pols_k2, pols_mk_mq2
        complex(kind=DP), allocatable, dimension(:, :, :) :: ifc3, d3, d3_pols, intermediate
        real(kind=DP) :: qe_omega 
        logical :: is_k_gamma, is_mk_mq_gamma, is_k_neg, is_mk_mq_neg
        logical, dimension(3) :: if_gammas
        
        allocate(rprim(3,3), qe_tau(3, nat), qe_bg(3,3))
        rprim = transpose(inv(kprim))
        !print*, 'Initialize self energy!'
        self_energy(:,:,:) = complex(0.0_DP, 0.0_DP)
        qe_tau = pos * A_TO_BOHR / qe_alat
        qe_bg = inv(rprim)*qe_alat / (A_TO_BOHR)
        qe_omega = abs(dot_product(cross(rprim(1,:), rprim(2,:)) , rprim(3,:))*A_TO_BOHR**3)
        !print*, 'Initialized self energy!'
        !$OMP PARALLEL DO IF(parallelize) &
        !$OMP DEFAULT(NONE) &
        !$OMP PRIVATE(jqpt, ifc3, d3, d3_pols, kpt, mkpt, qe_kpt, qe_mkpt, w2_k, pols_k, pols_k2, &
        !$OMP w2_mk_mq, pols_mk_mq, pols_mk_mq2, is_k_gamma, is_mk_mq_gamma, intermediate, &
        !$OMP is_k_neg, is_mk_mq_neg, w_k, w_mk_mq, i,j,k,i1,j1,k1,iat,jat,kat, freqs_array, if_gammas, selfnrg) &
        !$OMP SHARED(nqpt, qgrid, fc3, r3_2, r3_3, pos, qpt, nfc3, nat, nfc2, qe_zeu, fc2, r2_2, masses, is_q_gamma, smear, &
        !$OMP T, qe_alat, qe_omega, energies, ne, w_q, pols_q,weights, kprim, dielectric_tensor, qe_bg, qe_tau, &
        !$OMP gaussian, classical, long_range) &
        !$OMP REDUCTION(+:self_energy)
        do jqpt = 1, nqpt
            !print*, jqpt
            allocate(intermediate(3*nat, 3*nat, 3*nat))
            allocate(ifc3(3*nat, 3*nat, 3*nat), d3(3*nat, 3*nat, 3*nat), d3_pols(3*nat, 3*nat, 3*nat))
            allocate(selfnrg(ne, 3*nat, 3*nat))
            allocate(pols_k(3*nat,3*nat), pols_mk_mq(3*nat,3*nat))
            allocate(pols_k2(3*nat,3*nat), pols_mk_mq2(3*nat,3*nat))
            allocate(kpt(3), mkpt(3), qe_kpt(3), qe_mkpt(3))
            allocate(w2_k(3*nat), w2_mk_mq(3*nat), w_k(3*nat), w_mk_mq(3*nat))
            allocate(freqs_array(3*nat, 3))
            is_k_neg = .False.
            is_mk_mq_neg = .False.
            ifc3(:,:,:) = complex(0.0_DP, 0.0_DP) 
            d3(:,:,:) = complex(0.0_DP, 0.0_DP) 
            d3_pols(:,:,:) = complex(0.0_DP, 0.0_DP) 

            kpt = qgrid(:, jqpt)
            qe_kpt = kpt*qe_alat/A_TO_BOHR
            mkpt = -1.0_DP*qpt - kpt
            qe_mkpt = mkpt*qe_alat/A_TO_BOHR
            call interpol_v2(fc3, r3_2, r3_3, pos, kpt, mkpt, ifc3, nfc3, nat)
            !call interpolate_fc2(nfc2, nat, fc2, r2_2, masses, pos, kpt, w2_k, pols_k, pols_k2)
            call interpolate_fc2(nfc2, nat, fc2, qe_zeu, dielectric_tensor, qe_bg, r2_2, masses, pos, qe_tau, &
                               kpt, qe_kpt, qe_omega, qe_alat, long_range, w2_k, pols_k, pols_k2)
            !call interpolate_fc2(nfc2, nat, fc2, r2_2, masses, pos, mkpt, w2_mk_mq, pols_mk_mq, pols_mk_mq2)
            call interpolate_fc2(nfc2, nat, fc2, qe_zeu, dielectric_tensor, qe_bg, r2_2, masses, pos, qe_tau, &
                               mkpt, qe_mkpt, qe_omega, qe_alat, long_range, w2_mk_mq, pols_mk_mq, pols_mk_mq2)
    
            call check_if_gamma(nat, kpt, kprim, w2_k, is_k_gamma)
            call check_if_gamma(nat, mkpt, kprim, w2_mk_mq, is_mk_mq_gamma)
            if(any(w2_k < 0.0_DP) .and. .not. is_k_gamma) then
                print*, 'Negative eigenvalue of dynamical matrix! Exit!', is_k_gamma
                print*, kpt
                print*, vec_dot_mat(qpt, inv(kprim))
                print*, vec_dot_mat(kpt, inv(kprim))
                print*, vec_dot_mat(mkpt, inv(kprim))
                print*, kprim
                print*, w2_k
                is_k_neg = .True.
            endif
            if(any(w2_mk_mq < 0.0_DP) .and. .not. is_mk_mq_gamma) then
                print*, 'Negative eigenvalue of dynamical matrix! Exit!', is_mk_mq_gamma, 'mk_mq_gamma'
                print*, mkpt
                print*, vec_dot_mat(qpt, inv(kprim))
                print*, vec_dot_mat(kpt, inv(kprim))
                print*, vec_dot_mat(mkpt, inv(kprim))
                print*, kprim
                print*, w2_mk_mq
                is_mk_mq_neg = .True.
            endif
!            print*, 'Calculated frequencies! '
            if(.not. is_k_neg .and. .not. is_mk_mq_neg) then
            w_k = sqrt(w2_k)
            w_mk_mq = sqrt(w2_mk_mq)

            do iat = 1, nat
            do i = 1, 3
                do jat = 1, nat
                do j = 1, 3
                    do kat = 1, nat
                    do k = 1, 3
                        d3(k + 3*(kat - 1), j + 3*(jat - 1), i + 3*(iat - 1)) = &
                                       ifc3(k + 3*(kat - 1), j + 3*(jat - 1), i + 3*(iat - 1))&
                                        /sqrt(masses(iat)*masses(jat)*masses(kat))
                    enddo
                    enddo
                enddo
                enddo
            enddo
            enddo

            !do i = 1, 3*nat
            !do i1 = 1, 3*nat
            !    d3_pols(:,:,i) = d3_pols(:,:,i) + &
            !        matmul(matmul(transpose(pols_q), d3(:,:,i1)), pols_k)*pols_mk_mq(i1,i)
            !enddo
            !enddo
            intermediate = complex(0.0_DP, 0.0_DP)
            do i=1,3*nat
                intermediate(:,:,i) = matmul(matmul(transpose(pols_q), d3(:,:,i)), pols_k)
            enddo

            do i1=1,3*nat
                d3_pols(:,i1,:) = matmul(intermediate(:,i1,:), pols_mk_mq)
            enddo

            freqs_array(:, 1) = w_q
            freqs_array(:, 2) = w_k
            freqs_array(:, 3) = w_mk_mq

            if_gammas(1) = is_q_gamma
            if_gammas(2) = is_k_gamma
            if_gammas(3) = is_mk_mq_gamma
      
            selfnrg = complex(0.0_DP,0.0_DP)
            call compute_full_dynamic_bubble_single(energies, smear, T, freqs_array, if_gammas, &
                    d3_pols, ne, 3*nat, gaussian, classical, selfnrg)
!            print*, 'Got selfnrg!'
            self_energy = self_energy + selfnrg*dble(weights(jqpt))
            if(any(self_energy .ne. self_energy)) then
                    print*, 'NaN for jqpt', jqpt
            endif
            deallocate(intermediate)
            deallocate(ifc3, d3, d3_pols, selfnrg)
            deallocate(pols_k, pols_mk_mq)
            deallocate(pols_k2, pols_mk_mq2)
            deallocate(kpt, mkpt, qe_kpt, qe_mkpt)
            deallocate(w2_k, w2_mk_mq, w_k, w_mk_mq)
            deallocate(freqs_array)
            else
            deallocate(ifc3, d3, d3_pols, selfnrg)
            deallocate(pols_k, pols_mk_mq)
            deallocate(pols_k2, pols_mk_mq2)
            deallocate(kpt, mkpt)
            deallocate(w2_k, w2_mk_mq, w_k, w_mk_mq)
            deallocate(freqs_array)
            endif
        enddo
        !$OMP END PARALLEL DO
!        print*, 'Finished with self energy!'
    end subroutine calculate_self_energy_full

 !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

    subroutine check_if_gamma(nat, q, kprim, w2_q, is_gamma)

        implicit none
        integer, parameter :: DP = selected_real_kind(14,200)
        real(kind=DP), parameter :: PI = 3.141592653589793115997963468544185161590576171875

        integer, intent(in) :: nat
        real(kind=DP), dimension(3), intent(in) :: q
        real(kind=DP), intent(in) :: kprim(3,3)

        real(kind=DP), dimension(3*nat), intent(inout) :: w2_q
        logical, intent(out) :: is_gamma

        integer :: iat, i1, j1, k1
        real(kind=DP) :: ikprim(3,3), red_q(3)

        ikprim = inv(kprim)
        is_gamma = .FALSE.
        if(all(abs(q) < 1.0d-6)) then
            is_gamma = .TRUE.
            do iat = 1, 3
                w2_q(iat) = 0.0_DP
            enddo
        else
           red_q(:) = vec_dot_mat(q, ikprim)
           !do iat = 1, 3
           !     red_q = red_q + q(iat)*ikprim(iat, :)
           !enddo
           do iat = 1, 3
                red_q(iat) = red_q(iat) - dble(NINT(red_q(iat)))
           enddo
           if(all(abs(red_q) < 2.0d-3)) then
                is_gamma = .TRUE.
                do iat = 1, 3
                        w2_q(iat) = 0.0_DP
                enddo
           endif
        endif

    end subroutine

 !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

 function vec_dot_mat(v1, m1) result (v2)

        implicit none
        integer, parameter :: DP = selected_real_kind(14,200)
        real(kind=DP), parameter :: PI = 3.141592653589793115997963468544185161590576171875

        real(kind=DP),intent(in) :: m1(:,:), v1(:)
        real(kind=DP) :: v2(size(v1))

        integer :: i

        v2 = 0.0_DP
        do i = 1, 3
                v2 = v2 + v1(i)*m1(i,:)
        enddo 

 end function vec_dot_mat

 !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

 function cross(v1, v2) result (v3)

        implicit none
        integer, parameter :: DP = selected_real_kind(14,200)

        real(kind=DP),intent(in) :: v1(3), v2(3)
        real(kind=DP) :: v3(3)

        integer :: i

        v3 = 0.0_DP
        v3(1) = v1(2) * v2(3) - v1(3) * v2(2)
        v3(2) = v1(3) * v2(1) - v1(1) * v2(3)
        v3(3) = v1(1) * v2(2) - v1(2) * v2(1)

 end function cross

 !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

 subroutine calculate_real_part_via_Kramers_Kronig(ne, nband, self_energy, energies, freq)

        implicit none
        integer, parameter :: DP = selected_real_kind(14,200)
        real(kind=DP), parameter :: PI = 3.141592653589793115997963468544185161590576171875

        integer, intent(in) :: ne, nband
        real(kind=DP), intent(in) :: energies(ne), freq(nband)
        complex(kind=DP), intent(inout) :: self_energy(ne, nband)

        integer :: iband, i, j
        real(kind=DP) :: diff, suma, rse, correction
        real(kind=DP), dimension(ne) :: im_part

        do iband = 1, nband
                !im_part = self_energy(:,iband)/freq(iband)/2.0_DP
                do i = 1, ne
                        rse = 0.0_DP
                        do j = 1, ne
                                if(i .ne. j) then
                                        diff = 1.0_DP/(energies(j) - energies(i))
                                        suma = 1.0_DP/(energies(j) + energies(i))
                                        rse = rse + aimag(self_energy(j, iband))*(diff - suma)*(energies(2) - energies(1))/PI
                                else
                                        suma = 1.0_DP/(energies(j) + energies(i))
                                        rse = rse - aimag(self_energy(j, iband))*suma*(energies(2) - energies(1))/PI
                                endif
                        enddo
                        if(i > 1 .and. i < ne) then
                                correction = (aimag(self_energy(i+1, iband)) - aimag(self_energy(i-1, iband)))/2.0_DP
                        else 
                                correction = 0.0_DP
                        endif
                        self_energy(i, iband) = complex(rse + correction, aimag(self_energy(i, iband)))
                enddo
        enddo

 end subroutine

 !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

 subroutine calculate_real_part_via_Kramers_Kronig_2d(ne, nband, self_energy, energies, freq)

        implicit none
        integer, parameter :: DP = selected_real_kind(14,200)
        real(kind=DP), parameter :: PI = 3.141592653589793115997963468544185161590576171875

        integer, intent(in) :: ne, nband
        real(kind=DP), intent(in) :: energies(ne), freq(nband)
        complex(kind=DP), intent(inout) :: self_energy(ne, nband, nband)

        integer :: iband, jband, i, j
        real(kind=DP) :: diff, suma, rse, correction

        do iband = 1, nband
                do jband = 1, nband
                do i = 1, ne
                        rse = 0.0_DP
                        do j = 1, ne
                                if(i .ne. j) then
                                        diff = 1.0_DP/(energies(j) - energies(i))
                                        suma = 1.0_DP/(energies(j) + energies(i))
                                        rse = rse + aimag(self_energy(j, iband, jband))*(diff - suma)*(energies(2) - energies(1))/PI
                                else
                                        suma = 1.0_DP/(energies(j) + energies(i))
                                        rse = rse - aimag(self_energy(j, iband, jband))*suma*(energies(2) - energies(1))/PI
                                endif
                        enddo
                        if(i > 1 .and. i < ne) then
                                correction = (aimag(self_energy(i+1, iband, jband)) - aimag(self_energy(i-1, iband, jband)))/2.0_DP
                        else 
                                correction = 0.0_DP
                        endif
                        self_energy(i, iband, jband) = complex(rse + correction, aimag(self_energy(i, iband, jband)))
                enddo
                enddo
        enddo

 end subroutine

 !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

 subroutine hilbert_transform_via_FFT(ne, nband, self_energy)
 
        implicit none
        integer, parameter :: DP = selected_real_kind(14,200)
        real(kind=DP), parameter :: PI = 3.141592653589793115997963468544185161590576171875
 
        integer, intent(in) :: ne, nband
        complex(kind=DP), intent(inout) :: self_energy(ne, nband)
 
        integer :: iband, ie
        real(kind=DP) :: dummy(2*ne + 1)
       
        dummy = 0.0_DP
        do iband = 1, nband
                dummy(ne + 2:2*ne + 1) = aimag(self_energy(:,iband))
                dummy(1:ne) = -aimag(self_energy(:,iband))
                call ht(dummy, 2*ne + 1)
                do ie = 1, ne
                        self_energy(ie,iband) = complex(dummy(ie), aimag(self_energy(ie,iband)))
                enddo
        enddo 


 end subroutine hilbert_transform_via_FFT

 subroutine ht(x,n)

        implicit none
        integer, parameter :: DP = selected_real_kind(14,200)
        complex(kind=DP), parameter :: CI = (0.0_DP, 1.0_DP)
        integer, intent(in)    :: n
        real(kind=DP), intent(inout) :: x(n)

        complex(kind=DP), allocatable, dimension(:) :: C
        integer :: npt,imid

        ! pad x to a power of 2

        npt = 2**(INT(LOG10(dble(n))/0.30104)+1)

        allocate(C(npt))
        C=cmplx(0.0_DP,0.0_DP, kind=DP)
        C(1:n)=cmplx(x(1:n),0.0_DP, kind=DP)

        call CFFT(C,npt,1)
        C=C/dble(npt)

        imid = npt / 2
        C(1:imid-1) = -CI * C(1:imid-1)  
        C(imid) = 0.0_DP
        C(imid+1:npt) = CI * C(imid+1:npt)   ! neg. spectrum (i)

        ! inverse Fourier transform
        call  CFFT(C,npt,-1)

        ! output
        x(1:n)=dble(C(1:n))

        deallocate(C)

    end subroutine ht

 !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

    subroutine CFFT(x,n,isig)

        implicit none
        integer, parameter :: DP = selected_real_kind(14,200)
        real(kind=DP), parameter :: PI = 3.141592653589793115997963468544185161590576171875

        integer, intent(in)    :: n, isig
        complex(kind=DP), intent(inout) :: x(n)
        integer :: i1, i2a, i2b, i3, i3rev, ip1, ip2, isig1
        real(kind=DP)    ::  theta, sinth
        complex(kind=DP) :: temp, w, wstp

        isig1 = -isig
        i3rev = 1

        DO i3 = 1, n
                IF ( i3 < i3rev ) THEN  
                    temp = x(i3)
                    x(i3) = x(i3rev)
                    x(i3rev) = temp
                ENDIF
                ip1 = n / 2
                DO WHILE (  i3rev > ip1 )
                        IF ( ip1 <= 1 ) EXIT
                        i3rev = i3rev - ip1
                        ip1   = ip1 / 2
                END DO
                i3rev = i3rev + ip1
        END DO

        ip1 = 1

        DO WHILE  (ip1 < n)
                ip2   = ip1 * 2
                theta = 2.0_DP*pi/ dble(isig1*ip2)
                sinth = sin( theta / 2.0_DP)
                wstp  = complex(-2.0_DP*sinth*sinth, SIN(theta))
                w     = 1.0_DP

                DO i1 = 1, ip1
                        DO i3 = i1, n, ip2
                                i2a = i3
                                i2b = i2a + ip1
                                temp = w*x(i2b)
                                x(i2b) = x(i2a) - temp
                                x(i2a) = x(i2a) + temp
                        END DO
                        w = w*wstp+w
                END DO
                ip1 = ip2
        END DO

        RETURN
    END SUBROUTINE CFFT

 !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
 
    function inv(A) result(Ainv)
 
        implicit none
        integer, parameter :: DP = selected_real_kind(14,200)
        real(kind=DP), parameter :: PI = 3.141592653589793115997963468544185161590576171875

        real(kind=DP),intent(in) :: A(:,:)
        real(kind=DP)            :: Ainv(size(A,1),size(A,2))
        real(kind=DP)            :: work(size(A,1))            ! work array for LAPACK
        integer         :: n,info,ipiv(size(A,1))     ! pivot indices
 
        ! Store A in Ainv to prevent it from being overwritten by LAPACK
        Ainv = A
        n = size(A,1)
        ! DGETRF computes an LU factorization of a general M-by-N matrix A
        ! using partial pivoting with row interchanges.
        call DGETRF(n,n,Ainv,n,ipiv,info)
        if (info.ne.0) stop 'Matrix is numerically singular!'
        ! DGETRI computes the inverse of a matrix using the LU factorization
        ! computed by DGETRF.
        call DGETRI(n,Ainv,n,ipiv,work,n,info)
        if (info.ne.0) stop 'Matrix inversion failed!'
    end function inv
 
 !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

    subroutine interpolate_fc2(nfc2, nat, fc2, qe_zeu, dielectric_tensor, qe_bg, r2_2, masses, pos, qe_tau, &
                               q, qe_q, qe_omega, qe_alat, long_range, w2_q, pols_q, pols_q1)

        implicit none        
        integer, parameter :: DP = selected_real_kind(14,200)
        real(kind=DP), parameter :: PI = 3.141592653589793115997963468544185161590576171875

        integer, intent(in) :: nfc2, nat
        real(kind=DP), dimension(nfc2, 3*nat, 3*nat), intent(in) :: fc2 
        real(kind=DP), dimension(3, 3, nat), intent(in) :: qe_zeu
        real(kind=DP), dimension(3, nfc2), intent(in) :: r2_2
        real(kind=DP), dimension(3, nat), intent(in) :: pos, qe_tau
        real(kind=DP), dimension(3,3), intent(in) :: qe_bg, dielectric_tensor
        real(kind=DP), dimension(nat), intent(in) :: masses
        real(kind=DP), dimension(3), intent(in) :: q, qe_q
        real(kind=DP), intent(in) :: qe_omega, qe_alat
        logical, intent(in) :: long_range
        real(kind=DP), dimension(3*nat), intent(out) :: w2_q
        complex(kind=DP), dimension(3*nat, 3*nat), intent(out) :: pols_q, pols_q1

        integer :: ir, iat, jat, INFO, LWORK, i, j
        real(kind=DP), dimension(3) :: ruc
        complex(kind=DP), dimension(6*nat + 1) :: WORK
        real(kind=DP), dimension(9*nat - 2) :: RWORK
        real(kind=DP) :: phase


        pols_q1 = complex(0.0_DP,0.0_DP)
        do ir = 1, nfc2
            do iat = 1, nat
            do jat = 1, nat
                    !ruc = pos(:,jat) - pos(:,iat) - r2_2(:,ir)
                    ! Have to keep this phase convention to be consistent with Fourier transform of the 3rd order force constants!
                    ruc = r2_2(:,ir)
                    phase = dot_product(ruc, q)*2.0_DP*PI
                    pols_q1(3*(jat - 1) + 1:3*jat, 3*(iat - 1) + 1:3*iat) = pols_q1(3*(jat - 1) + 1:3*jat, 3*(iat - 1) + 1:3*iat) &
                            + fc2(ir,3*(jat - 1) + 1:3*jat, 3*(iat - 1) + 1:3*iat)*exp(complex(0.0_DP, phase))
            enddo
            enddo
        enddo

        if(long_range) then
           call add_long_range(nat, pos, dielectric_tensor, qe_zeu, qe_q, qe_tau, qe_bg, qe_omega, qe_alat, pols_q1)
        endif

        do iat = 1, nat
        do i = 1, 3 
            do jat = 1, nat
            do j = 1, 3
                pols_q1(j + 3*(jat - 1),i + 3*(iat - 1)) = pols_q1(j + 3*(jat - 1),i + 3*(iat - 1))/sqrt(masses(iat)*masses(jat))
            enddo
            enddo
        enddo
        enddo

        pols_q = (pols_q1 + conjg(transpose(pols_q1)))/2.0_DP
        pols_q1 = (pols_q1 + conjg(transpose(pols_q1)))/2.0_DP
        LWORK = -1
        call zheev('V', 'L', 3*nat, pols_q, 3*nat, w2_q, WORK, LWORK, RWORK, INFO)
        LWORK = MIN( size(WORK), INT( WORK( 1 ) ) )
        call zheev('V', 'L', 3*nat, pols_q, 3*nat, w2_q, WORK, LWORK, RWORK, INFO)
        
        !if(any(w2_q < 0.0_DP)) then
        !        print*, 'Negative in interolate'
        !        print*, q, qe_q
        !        print*, dielectric_tensor
        !        print*, qe_zeu
        !        print*, qe_bg
        !        print*, vec_dot_mat(qe_q, inv(qe_bg))
        !        print*, qe_omega, qe_alat
        !        STOP
        !endif

    end subroutine

    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

    subroutine add_long_range(nat, pos, dielectric_tensor, qe_zeu, qe_q, qe_tau, qe_bg, qe_omega, qe_alat, pols_q1)

        implicit none        
        integer, parameter :: DP = selected_real_kind(14,200)
        real(kind=DP), parameter :: PI = 3.141592653589793115997963468544185161590576171875, A_TO_BOHR = 1.889725989_DP

        integer, intent(in) :: nat
        real(kind=DP), intent(in) :: qe_omega, qe_alat
        real(kind=DP), dimension(3, nat), intent(in) :: pos, qe_tau
        real(kind=DP), dimension(3, 3, nat), intent(in) :: qe_zeu
        real(kind=DP), dimension(3,3), intent(in) :: qe_bg, dielectric_tensor
        real(kind=DP), dimension(3), intent(in) :: qe_q

        complex(kind=DP), dimension(3*nat, 3*nat), intent(inout) :: pols_q1

        integer :: ir, iat, jat, i, j, qe_itau(nat)
        complex(kind=DP), dimension(3, 3, nat, nat) :: pols_q2
        real(kind=DP), dimension(3) :: ruc, q_vect
        real(kind=DP) :: phase

        pols_q2 = complex(0.0_DP, 0.0_DP)
        do iat = 1, nat
           qe_itau(iat) = iat
           do jat = 1, nat
              do i = 1, 3
                 do j = 1, 3
                    pols_q2(j,i,jat,iat) = pols_q1(3*(jat - 1) + j, 3*(iat-1) + i)
                 enddo
              enddo
           enddo
        enddo

        call rgd_blk(0, 0, 0, nat, pols_q2, qe_q, qe_tau, dielectric_tensor, qe_zeu, qe_bg, qe_omega, qe_alat, .FALSE. , +1.0_DP)

        if(sqrt(dot_product(qe_q, qe_q)) < 1.0d-8) then
           call random_number(q_vect)
           q_vect = q_vect/sqrt(dot_product(q_vect,q_vect))
           call nonanal(nat, nat, qe_itau, dielectric_tensor, q_vect, qe_zeu, qe_omega, pols_q2)
        endif

        do iat = 1, nat
           do jat = 1, nat
              do i = 1, 3
                 do j = 1, 3
                    pols_q1(3*(jat - 1) + j, 3*(iat-1) + i) = pols_q2(j,i,jat,iat)
                 enddo
              enddo
           enddo
        enddo

    end subroutine

    subroutine rgd_blk (nr1,nr2,nr3,nat,dyn,q,tau,epsil,zeu,bg,omega,alat,loto_2d,sign)
           !-----------------------------------------------------------------------
           ! compute the rigid-ion (long-range) term for q
           ! The long-range term used here, to be added to or subtracted from the
           ! dynamical matrices, is exactly the same of the formula introduced in:
           ! X. Gonze et al, PRB 50. 13035 (1994) . Only the G-space term is
           ! implemented: the Ewald parameter alpha must be large enough to
           ! have negligible r-space contribution
           !

           implicit none

           INTEGER, PARAMETER :: DP = selected_real_kind(14,200)
           REAL(DP), PARAMETER :: pi     = 3.14159265358979323846_DP
           REAL(DP), PARAMETER :: tpi    = 2.0_DP * pi
           REAL(DP), PARAMETER :: fpi    = 4.0_DP * pi
           REAL(DP), PARAMETER :: e2 = 2.0_DP      ! the square of the electron charge

           integer ::  nr1, nr2, nr3    !  FFT grid
           integer ::  nat              ! number of atoms
           complex(DP) :: dyn(3,3,nat,nat) ! dynamical matrix
           real(DP) &
                q(3),           &! q-vector
                tau(3,nat),     &! atomic positions
                epsil(3,3),     &! dielectric constant tensor
                zeu(3,3,nat),   &! effective charges tensor
                at(3,3),        &! direct     lattice basis vectors
                bg(3,3),        &! reciprocal lattice basis vectors
                omega,          &! unit cell volume
                alat,           &! cell dimension units 
                sign             ! sign=+/-1.0 ==> add/subtract rigid-ion term
           logical :: loto_2d ! 2D LOTO correction 
           !
           ! local variables
           !
           real(DP):: geg, gp2, r                    !  <q+G| epsil | q+G>,  For 2d loto: gp2, r
           integer :: na,nb, i,j, m1, m2, m3
           integer :: nr1x, nr2x, nr3x
           real(DP) :: alph, fac,g1,g2,g3, facgd, arg, gmax, alat_new
           real(DP) :: zag(3),zbg(3),zcg(3), fnat(3), reff(2,2)
           real :: time1, time2
           complex(dp) :: facg
           !
           ! alph is the Ewald parameter, geg is an estimate of G^2
           ! such that the G-space sum is convergent for that alph
           ! very rough estimate: geg/4/alph > gmax = 14
           ! (exp (-14) = 10^-6)
           !
           call cpu_time(time1)
           gmax= 14.d0
           alph= 1.0d0
           geg = gmax*alph*4.0d0
         
            !print *, ""
            !print *, "[RGD_BLK] Q = ", q
            !print *, "[RGD_BLK] NAT:", nat
            !print *, "[RGD_BLK] OMEGA:", omega
            !print *, "[RGD_BLK] ZEU:"
            !do i = 1, nat
            !   do j = 1, 3
            !      print *, zeu(:, j, i)
            !   enddo
            !end do
            !print *, "[RGD_BLK] ALAT:", alat
            !print *, "[RGD_BLK] BG:"
            !do i = 1, 3
            !   print *, bg(:, i)
            !end do
            !print *, "[RGD_BLK] TAU:"
            !do i = 1, nat
            !   print *, tau(:, i)
            !end do

            !print *, "[RGD_BLK] EPSIL:"
            !do i = 1, 3
            !   print *, epsil(:, i)
            !end do
         
            !print *, "[RGD_BLK] DYN:"
            !do na = 1, nat
            !   do nb = 1, nat
            !      do i = 1, 3
            !         print *,  dyn(:, i, na, nb)
            !      end do
            !   end do
            !end do
           
           ! Silicon 
           alat_new = 10.0d0
           
         
           ! Estimate of nr1x,nr2x,nr3x generating all vectors up to G^2 < geg
           ! Only for dimensions where periodicity is present, e.g. if nr1=1
           ! and nr2=1, then the G-vectors run along nr3 only.
           ! (useful if system is in vacuum, e.g. 1D or 2D)
           !
           if (nr1 == 1) then
              nr1x=0
           else
              nr1x = int ( sqrt (geg) / &
                           (sqrt (bg (1, 1) **2 + bg (2, 1) **2 + bg (3, 1) **2) )) + 1
           endif
           if (nr2 == 1) then
              nr2x=0
           else
              nr2x = int ( sqrt (geg) / &
                           ( sqrt (bg (1, 2) **2 + bg (2, 2) **2 + bg (3, 2) **2) )) + 1
           endif
           if (nr3 == 1) then
              nr3x=0
           else
              nr3x = int ( sqrt (geg) / &
                           (sqrt (bg (1, 3) **2 + bg (2, 3) **2 + bg (3, 3) **2) )) + 1
           endif
           !
         
           !print *, "[RGD_BLK] integration grid:", nr1x, nr2x, nr3x
           if (abs(sign) /= 1.0_DP) &
                call errore ('rgd_blk',' wrong value for sign ',1)
           !
           IF (loto_2d) THEN 
              fac = sign*e2*fpi/omega*0.5d0*alat/bg(3,3)
              reff=0.0d0
              DO i=1,2
                 DO j=1,2
                    reff(i,j)=epsil(i,j)*0.5d0*tpi/bg(3,3) ! (eps)*c/2 in 2pi/a units
                 ENDDO
              ENDDO
              DO i=1,2
                 reff(i,i)=reff(i,i)-0.5d0*tpi/bg(3,3) ! (-1)*c/2 in 2pi/a units
              ENDDO 
           ELSE
             fac = sign*e2*fpi/omega
           ENDIF
           do m1 = -nr1x,nr1x
           do m2 = -nr2x,nr2x
           do m3 = -nr3x,nr3x
              !
              g1 = m1*bg(1,1) + m2*bg(1,2) + m3*bg(1,3)
              g2 = m1*bg(2,1) + m2*bg(2,2) + m3*bg(2,3)
              g3 = m1*bg(3,1) + m2*bg(3,2) + m3*bg(3,3)
              !
              IF (loto_2d) THEN 
                 geg = g1**2 + g2**2 + g3**2
                 r=0.0d0
                 gp2=g1**2+g2**2
                 IF (gp2>1.0d-8) THEN
                    r=g1*reff(1,1)*g1+g1*reff(1,2)*g2+g2*reff(2,1)*g1+g2*reff(2,2)*g2
                    r=r/gp2
                 ENDIF
              ELSE
                  geg = (g1*(epsil(1,1)*g1+epsil(1,2)*g2+epsil(1,3)*g3)+      &
                     g2*(epsil(2,1)*g1+epsil(2,2)*g2+epsil(2,3)*g3)+      &
                     g3*(epsil(3,1)*g1+epsil(3,2)*g2+epsil(3,3)*g3))
              ENDIF
              !
              if (geg > 0.0_DP .and. geg/alph/4.0_DP < gmax ) then
                 !
                 IF (loto_2d) THEN 
                   facgd = fac*exp(-geg/alph/4.0d0)/SQRT(geg)/(1.0+r*SQRT(geg)) 
                 ELSE
                   facgd = fac*exp(-geg/alph/4.0d0)/geg
                 ENDIF
                 !
                 do na = 1,nat
                    zag(:)=g1*zeu(1,:,na)+g2*zeu(2,:,na)+g3*zeu(3,:,na)
                    fnat(:) = 0.d0
                    do nb = 1,nat
                       arg = 2.d0*pi* (g1 * (tau(1,na)-tau(1,nb))+             &
                                       g2 * (tau(2,na)-tau(2,nb))+             &
                                       g3 * (tau(3,na)-tau(3,nb)))
                       zcg(:) = g1*zeu(1,:,nb) + g2*zeu(2,:,nb) + g3*zeu(3,:,nb)
                       fnat(:) = fnat(:) + zcg(:)*cos(arg)
                    end do
                    do j=1,3
                       do i=1,3
                          dyn(i,j,na,na) = dyn(i,j,na,na) - facgd * &
                                           zag(i) * fnat(j)
                       end do
                    end do
                 end do
              end if
              !
              g1 = g1 + q(1)
              g2 = g2 + q(2)
              g3 = g3 + q(3)
              !
              IF (loto_2d) THEN 
                 geg = g1**2+g2**2+g3**2
                 r=0.0d0
                 gp2=g1**2+g2**2
                 IF (gp2>1.0d-8) THEN
                    r=g1*reff(1,1)*g1+g1*reff(1,2)*g2+g2*reff(2,1)*g1+g2*reff(2,2)*g2
                    r=r/gp2
                 ENDIF
              ELSE
              geg = (g1*(epsil(1,1)*g1+epsil(1,2)*g2+epsil(1,3)*g3)+      &
                     g2*(epsil(2,1)*g1+epsil(2,2)*g2+epsil(2,3)*g3)+      &
                     g3*(epsil(3,1)*g1+epsil(3,2)*g2+epsil(3,3)*g3))
              ENDIF
              !
              if (geg > 0.0_DP .and. geg/alph/4.0_DP < gmax ) then
                 !
                 IF (loto_2d) THEN 
                   facgd = fac*exp(-geg/alph/4.0d0)/SQRT(geg)/(1.0+r*SQRT(geg))
                 ELSE
                   facgd = fac*exp(-geg/alph/4.0d0)/geg
                 ENDIF
                 !
                 do nb = 1,nat
                    zbg(:)=g1*zeu(1,:,nb)+g2*zeu(2,:,nb)+g3*zeu(3,:,nb)
                    do na = 1,nat
                       zag(:)=g1*zeu(1,:,na)+g2*zeu(2,:,na)+g3*zeu(3,:,na)
                       arg = 2.d0*pi* (g1 * (tau(1,na)-tau(1,nb))+             &
                                       g2 * (tau(2,na)-tau(2,nb))+             &
                                       g3 * (tau(3,na)-tau(3,nb)))
                       !
                       facg = facgd * CMPLX(cos(arg),sin(arg),kind=DP)
                       do j=1,3
                          do i=1,3
                             dyn(i,j,na,nb) = dyn(i,j,na,nb) + facg *      &
                                              zag(i) * zbg(j)
                          end do
                       end do
                    end do
                 end do
              end if
           end do
           end do
         end do
         
        !  call cpu_time(time2)
        !  print *, "Elapsed time in rgd_blk: ", time2 - time1
         
         
        !   print *, ""
        !   print *, "[RGD_BLK] DYN FINAL:"
        !   do na = 1, nat
        !      do nb = 1, nat
        !         do i = 1, 3
        !            print *,  dyn(:, i, na, nb)
        !         end do
        !      end do
        !   end do
         
        !   print *, ""
        !   print *, ""
        !  print *, "----------------------------------------------------"
         
          
         
           !
           return
           !
         end subroutine rgd_blk
         
        !-----------------------------------------------------------------------
        subroutine nonanal(nat, nat_blk, itau_blk, epsil, q, zeu, omega, dyn )
          !-----------------------------------------------------------------------
          !     add the nonanalytical term with macroscopic electric fields
          !     See PRB 55, 10355 (1997) Eq (60)
          !
          use kinds, only: dp
          use constants, only: pi, fpi, e2
         implicit none
         integer, intent(in) :: nat, nat_blk, itau_blk(nat)
         !  nat: number of atoms in the cell (in the supercell in the case
         !       of a dyn.mat. constructed in the mass approximation)
         !  nat_blk: number of atoms in the original cell (the same as nat if
         !       we are not using the mass approximation to build a supercell)
         !  itau_blk(na): atom in the original cell corresponding to
         !                atom na in the supercell
         !
         complex(DP), intent(inout) :: dyn(3,3,nat,nat) ! dynamical matrix
         real(DP), intent(in) :: q(3),  &! polarization vector
              &       epsil(3,3),     &! dielectric constant tensor
              &       zeu(3,3,nat_blk),   &! effective charges tensor
              &       omega            ! unit cell volume
         !
         ! local variables
         !
         real(DP) zag(3),zbg(3),  &! eff. charges  times g-vector
              &       qeq              !  <q| epsil | q>
         integer na,nb,              &! counters on atoms
              &  na_blk,nb_blk,      &! as above for the original cell
              &  i,j                  ! counters on cartesian coordinates
         !
         qeq = (q(1)*(epsil(1,1)*q(1)+epsil(1,2)*q(2)+epsil(1,3)*q(3))+    &
                q(2)*(epsil(2,1)*q(1)+epsil(2,2)*q(2)+epsil(2,3)*q(3))+    &
                q(3)*(epsil(3,1)*q(1)+epsil(3,2)*q(2)+epsil(3,3)*q(3)))
         !
        !print*, q(1), q(2), q(3)
         if (qeq < 1.d-8) then
            write(6,'(5x,"A direction for q was not specified:", &
              &          "TO-LO splitting will be absent")')
            return
         end if
         !
         do na = 1,nat
            na_blk = itau_blk(na)
            do nb = 1,nat
               nb_blk = itau_blk(nb)
               !
               do i=1,3
                  !
                  zag(i) = q(1)*zeu(1,i,na_blk) +  q(2)*zeu(2,i,na_blk) + &
                           q(3)*zeu(3,i,na_blk)
                  zbg(i) = q(1)*zeu(1,i,nb_blk) +  q(2)*zeu(2,i,nb_blk) + &
                           q(3)*zeu(3,i,nb_blk)
               end do
               !
               do i = 1,3
                  do j = 1,3
                     dyn(i,j,na,nb) = dyn(i,j,na,nb)+ fpi*e2*zag(i)*zbg(j)/qeq/omega
        !             print*, zag(i),zbg(j),qeq, fpi*e2*zag(i)*zbg(j)/qeq/omega
                  end do
               end do
            end do
         end do
         !
         return
        end subroutine nonanal


        SUBROUTINE trasl( phid, phiq, nq, nr1, nr2, nr3, nat, m1, m2, m3 )
           !----------------------------------------------------------------------------
           !
           USE kinds, ONLY : DP
           !
           IMPLICIT NONE
           INTEGER, intent(in) ::  nr1, nr2, nr3, m1, m2, m3, nat, nq
           COMPLEX(DP), intent(in) :: phiq(3,3,nat,nat,48)
           COMPLEX(DP), intent(out) :: phid(nr1,nr2,nr3,3,3,nat,nat)
           !
           INTEGER :: j1,j2,  na1, na2
           !
           DO j1=1,3
              DO j2=1,3
                 DO na1=1,nat
                    DO na2=1,nat
                       phid(m1,m2,m3,j1,j2,na1,na2) = &
                            0.5d0 * (      phiq(j1,j2,na1,na2,nq) +  &
                                   CONJG(phiq(j2,j1,na2,na1,nq)))
                    END DO
                 END DO
              END DO
           END DO
           !
           RETURN
         END SUBROUTINE trasl
 

end module get_lf
