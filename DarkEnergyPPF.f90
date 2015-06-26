    module DarkEnergyPPF
    use precision
    use ModelParams
    use RandUtils
    use DarkEnergyInterface
    implicit none

    integer, parameter :: nwmax = 5000
    integer, private, parameter :: nde = 2000
    real(dl), private, parameter :: amin = 1.d-9

    type, extends(TDarkEnergyBase) :: TDarkEnergyPPF
        ! w_lam is now w0
        real(dl) :: cs2_lam = 1_dl
        !comoving sound speed. Always exactly 1 for quintessence
        !(otherwise assumed constant, though this is almost certainly unrealistic)

        logical :: use_tabulated_w = .false.
        real(dl) :: c_Gamma_ppf = 0.4_dl
        integer :: nw_ppf
        real(dl) w_ppf(nwmax), a_ppf(nwmax)
        real(dl), private :: ddw_ppf(nwmax)
        real(dl), private :: rde(nde),ade(nde),ddrde(nde)
        logical :: is_cosmological_constant
        ! for output and derivs
        real(dl), private :: w_eff

        !PPF parameters for dervis
        real(dl) dgrho_e_ppf, dgq_e_ppf
    contains
    procedure :: ReadParams => TDarkEnergyPPF_ReadParams
    procedure :: Init_Background => TDarkEnergyPPF_Init_Background
    procedure :: dtauda_Add_Term => TDarkEnergyPPF_dtauda_Add_Term
    procedure :: SetupIndices => TDarkEnergyPPF_SetupIndices
    procedure :: PrepYout => TDarkEnergyPPF_PrepYout
    procedure :: OutputPreMassiveNu => TDarkEnergyPPF_OutputPreMassiveNu
    procedure :: diff_rhopi_Add_Term => TDarkEnergyPPF_diff_rhopi_Add_Term
    procedure :: InitializeYfromVec => TDarkEnergyPPF_InitializeYfromVec
    procedure :: DerivsPrep => TDarkEnergyPPF_DerivsPrep
    procedure :: DerivsAddPreSigma => TDarkEnergyPPF_DerivsAddPreSigma
    procedure, private :: setddwa
    procedure, private :: interpolrde
    procedure, private :: grho_de
    procedure, private :: setcgammappf
    end type TDarkEnergyPPF

    private w_de, cubicsplint
    contains

    subroutine TDarkEnergyPPF_ReadParams(this, Ini)
    use IniObjects
    class(TDarkEnergyPPF), intent(inout) :: this
    type(TIniFile), intent(in) :: Ini
    character(len=:), allocatable :: wafile
    integer i

    if (Ini%HasKey('usew0wa')) then
        stop 'input variables changed from usew0wa: now use_tabulated_w or w, wa'
    end if

    this%use_tabulated_w = Ini%Read_Logical('use_tabulated_w', .false.)
    if(.not. this%use_tabulated_w)then
        this%w_lam = Ini%Read_Double('w', -1.d0)
        this%wa_ppf = Ini%Read_Double('wa', 0.d0)
        if (Rand_Feedback >0) write(*,'("(w0, wa) = (", f8.5,", ", f8.5, ")")') &
        &   this%w_lam, this%wa_ppf
    else
        wafile = Ini%Read_String('wafile')
        open(unit=10, file=wafile, status='old')
        this%nw_ppf=0
        do i=1, nwmax + 1
            read(10, *, end=100) this%a_ppf(i), this%w_ppf(i)
            this%a_ppf(i) = dlog(this%a_ppf(i))
            this%nw_ppf = this%nw_ppf + 1
        enddo
        write(*,'("Note: ", a, " has more than ", I8, " data points")') &
        &   trim(wafile), nwmax
        write(*,*)'Increase nwmax in LambdaGeneral'
        stop
100     close(10)
        write(*,'("read in ", I8, " (a, w) data points from ", a)') &
        &   this%nw_ppf, trim(wafile)
        call this%setddwa
        call this%interpolrde
    endif
    this%cs2_lam = Ini%Read_Double('cs2_lam', 1.d0)
    call this%setcgammappf

    end subroutine TDarkEnergyPPF_ReadParams


    subroutine setddwa(this)
    class(TDarkEnergyPPF) :: this
    real(dl), parameter :: wlo = 1.d30, whi = 1.d30

    call spline(this%a_ppf, this%w_ppf, this%nw_ppf, wlo, whi, this%ddw_ppf) !a_ppf is lna here

    end subroutine setddwa


    function w_de(curr, a)
    type(TDarkEnergyPPF), intent(in) :: curr
    real(dl) :: w_de, al
    real(dl), intent(IN) :: a

    if(.not. curr%use_tabulated_w) then
        w_de= curr%w_lam+ curr%wa_ppf*(1._dl-a)
    else
        al=dlog(a)
        if(al .lt. curr%a_ppf(1)) then
            w_de= curr%w_ppf(1)                   !if a < minimum a from wa.dat
        elseif(al .gt. curr%a_ppf(curr%nw_ppf)) then
            w_de= curr%w_ppf(curr%nw_ppf)         !if a > maximus a from wa.dat
        else
            call cubicsplint(curr%a_ppf, curr%w_ppf, curr%ddw_ppf, &
            &   curr%nw_ppf, al, w_de)
        endif
    endif
    end function w_de  ! equation of state of the PPF DE


    function drdlna_de(curr, al)
    type(TDarkEnergyPPF), intent(in) :: curr
    real(dl) :: drdlna_de, a
    real(dl), intent(IN) :: al

    a = dexp(al)
    drdlna_de = 3._dl * (1._dl + w_de(curr, a))

    end function drdlna_de


    subroutine interpolrde(this)
    class(TDarkEnergyPPF), target :: this
    real(dl), parameter :: rlo=1.d30, rhi=1.d30
    real(dl) :: atol, almin, al, rombint, fint
    integer :: i
    external rombint

    atol = 1.d-5
    almin = dlog(amin)
    do i = 1, nde
        al = almin - almin / (nde - 1) * (i - 1) !interpolate between amin and today
        fint = rombint(drdlna_de, al, 0._dl, atol) + 4._dl * al
        this%ade(i) = al
        this%rde(i) = dexp(fint) !rho_de*a^4 normalize to its value at today
    enddo
    call spline(this%ade, this%rde, nde, rlo, rhi, this%ddrde)

    end subroutine interpolrde


    function grho_de(this, a)  !8 pi G a^4 rho_de
    class(TDarkEnergyPPF), target :: this
    real(dl) :: grho_de, al, fint
    real(dl), intent(IN) :: a

    if(.not. this%use_tabulated_w) then
        grho_de = grhov * a ** (1._dl - 3. * this%w_lam - 3. * this%wa_ppf) * &
            exp(-3. * this%wa_ppf * (1._dl - a))
    else
        if(a .eq. 0.d0)then
            grho_de = 0.d0      !assume rho_de*a^4-->0, when a-->0, OK if w_de always <0.
        else
            al = dlog(a)
            if(al .lt. this%ade(1))then
                        !if a<amin, assume here w=w_de(amin)
                fint = this%rde(1) * (a / amin) ** (1. - 3. * w_de(this, amin))
            else        !if amin is small enough, this extrapolation will be unnecessary.
                call cubicsplint(this%ade, this%rde, this%ddrde, nde, al, fint)
            endif
            grho_de = grhov*fint
        endif
    endif

    end function grho_de


    !-------------------------------------------------------------------
    SUBROUTINE cubicsplint(xa,ya,y2a,n,x,y)
    INTEGER n
    real(dl)x,y,xa(n),y2a(n),ya(n)
    INTEGER k,khi,klo
    real(dl)a,b,h
    klo=1
    khi=n
1   if (khi-klo.gt.1) then
        k=(khi+klo)/2
        if(xa(k).gt.x)then
            khi=k
        else
            klo=k
        endif
        goto 1
    endif
    h=xa(khi)-xa(klo)
    if (h.eq.0.) stop 'bad xa input in splint'
    a=(xa(khi)-x)/h
    b=(x-xa(klo))/h
    y=a*ya(klo)+b*ya(khi)+&
        ((a**3-a)*y2a(klo)+(b**3-b)*y2a(khi))*(h**2)/6.d0
    END SUBROUTINE cubicsplint
    !--------------------------------------------------------------------


    subroutine setcgammappf(this)
    class(TDarkEnergyPPF) :: this

    this%c_Gamma_ppf=0.4d0*sqrt(this%cs2_lam)

    end subroutine setcgammappf


    subroutine TDarkEnergyPPF_Init_Background(this)
    class(TDarkEnergyPPF) :: this
    !This is only called once per model, and is a good point to do any extra initialization.
    !It is called before first call to dtauda, but after
    !massive neutrinos are initialized and after GetOmegak
    this%is_cosmological_constant = .not. this%use_tabulated_w .and. &
    &   this%w_lam==-1_dl .and. this%wa_ppf==0._dl
    end  subroutine TDarkEnergyPPF_Init_Background


    !Background evolution
    function TDarkEnergyPPF_dtauda_Add_Term(this, a) result(grhoa2)
    !get d tau / d a
    use precision
    use ModelParams
    use MassiveNu
    implicit none
    class (TDarkEnergyPPF), intent(in) :: this
    real(dl) dtauda
    real(dl), intent(IN) :: a
    real(dl) rhonu, grhoa2
    integer nu_i

    grhoa2 = 0._dl
    if (this%is_cosmological_constant) then
        grhoa2 = grhov * (a * a) ** 2
    else
        grhoa2 = grho_de(this, a)
    end if

    if (CP%Num_Nu_massive /= 0) then
        !Get massive neutrino density relative to massless
        do nu_i = 1, CP%nu_mass_eigenstates
            call Nu_rho(a * nu_masses(nu_i), rhonu)
            grhoa2 = grhoa2 + rhonu * grhormass(nu_i)
        end do
    end if

    end function TDarkEnergyPPF_dtauda_Add_Term


    subroutine TDarkEnergyPPF_SetupIndices(this, w_ix, neq, maxeq)
    class(TDarkEnergyPPF), intent(in) :: this
    integer, intent(inout) :: w_ix, neq, maxeq

    if (.not. this%is_cosmological_constant) then
        w_ix = neq+1
        neq = neq+1 !ppf
        maxeq = maxeq+1
    else
        w_ix=0
    end if

    end subroutine TDarkEnergyPPF_SetupIndices


    subroutine TDarkEnergyPPF_PrepYout(this, w_ix_out, w_ix, yout, y)
    class(TDarkEnergyPPF), intent(in) :: this
    integer, intent(in) :: w_ix_out, w_ix
    real(dl), intent(inout) :: yout(:)
    real(dl), intent(in) :: y(:)

    if (.not. this%is_cosmological_constant) then
        yout(w_ix_out) = y(w_ix)
    end if

    end subroutine TDarkEnergyPPF_PrepYout


    subroutine TDarkEnergyPPF_OutputPreMassiveNu(this, grhov_t, grho, gpres, dgq, dgrho, &
        a, grhov, grhob_t, grhoc_t, grhor_t, grhog_t)
    class(TDarkEnergyPPF), intent(inout) :: this
    real(dl), intent(inout) :: grhov_t, grho, gpres, dgq, dgrho
    real(dl), intent(in) :: a, grhov, grhob_t, grhoc_t, grhor_t, grhog_t
    real(dl) :: a2

    a2 = a * a

    if (this%is_cosmological_constant) then
        this%w_eff = -1_dl
        grhov_t = grhov * a2
    else
        !ppf
        this%w_eff = w_de(this, a)   !effective de
        grhov_t = grho_de(this, a) / a2
        dgrho = dgrho + this%dgrho_e_ppf
        dgq = dgq + this%dgq_e_ppf
    end if
    grho = grhob_t + grhoc_t + grhor_t + grhog_t + grhov_t
    gpres = (grhog_t + grhor_t) / 3 + grhov_t * this%w_eff

    end subroutine TDarkEnergyPPF_OutputPreMassiveNu


    function TDarkEnergyPPF_diff_rhopi_Add_Term(this, grho, gpres, grhok, adotoa, &
        EV_KfAtOne, k, grhov_t, z, k2, yprime, y, w_ix) result(ppiedot)
    class(TDarkEnergyPPF), intent(in) :: this
    real(dl), intent(in) :: grho, gpres, grhok, adotoa, &
        k, grhov_t, z, k2, yprime(:), y(:), EV_KfAtOne
    integer, intent(in) :: w_ix
    real(dl) :: ppiedot, hdotoh

    if (this%is_cosmological_constant) then
        ppiedot = 0
    else
        hdotoh = (-3._dl * grho - 3._dl * gpres - 2._dl * grhok) / 6._dl / adotoa
        ppiedot = 3._dl * this%dgrho_e_ppf + this%dgq_e_ppf * &
            (12._dl / k * adotoa + k / adotoa - 3._dl / k * (adotoa + hdotoh)) + &
            grhov_t * (1 + this%w_eff) * k * z / adotoa - 2._dl * k2 * EV_KfAtOne * &
            (yprime(w_ix) / adotoa - 2._dl * y(w_ix))
        ppiedot = ppiedot * adotoa / EV_KfAtOne
    end if

    end function TDarkEnergyPPF_diff_rhopi_Add_Term


    subroutine TDarkEnergyPPF_InitializeYfromVec(this, y, EV_w_ix, InitVecAti_clxq, &
        InitVecAti_vq)
    class(TDarkEnergyPPF), intent(in) :: this
    real(dl), intent(inout) :: y(:)
    integer, intent(in) :: EV_w_ix
    real(dl), intent(in) :: InitVecAti_clxq, InitVecAti_vq

    if (.not. this%is_cosmological_constant) then
        y(EV_w_ix) = InitVecAti_clxq !ppf: Gamma=0, i_clxq stands for i_Gamma
    end if

    end subroutine TDarkEnergyPPF_InitialzeYfromVec


    subroutine TDarkEnergyPPF_DerivsPrep(this, grhov_t, &
        a, grhov, grhor_t, grhog_t, gpres)
    class(TDarkEnergyPPF), intent(inout) :: this
    real(dl), intent(inout) :: grhov_t
    real(dl), intent(inout), optional :: gpres
    real(dl), intent(in) :: a, grhov, grhor_t, grhog_t

    if (this%is_cosmological_constant) then
        grhov_t = grhov * a * a
        this%w_eff = -1_dl
    else
        !ppf
        this%w_eff = w_de(this, a)   !effective de
        grhov_t = grho_de(this, a) / (a * a)
    end if
    if (present(gpres)) gpres = (grhor_t + grhog_t) / 3._dl

    end subroutine TDarkEnergyPPF_DerivsPrep

    subroutine TDarkEnergyPPF_DerivsAddPreSigma(this, sigma, &
        ayprime, dgq, dgrho, &
        grho, grhov_t, gpres, ay, w_ix, etak, adotoa, k, k2, EV_kf1)
    class(TDarkEnergyPPF), intent(inout) :: this
    real(dl), intent(inout) :: sigma, ayprime(:), dgq, dgrho
    real(dl), intent(in) :: grho, grhov_t, gpres, ay(:), etak
    real(dl), intent(in) :: adotoa, k, k2, EV_kf1
    integer, intent(in) :: w_ix

    real(dl) :: Gamma, S_Gamma, ckH, Gammadot, Fa, dgqe, dgrhoe
    real(dl) :: vT, grhoT

    if (.not. this%is_cosmological_constant) then
        !ppf
        grhoT = grho - grhov_t
        vT = dgq / (grhoT + gpres)
        Gamma = ay(w_ix)

        !sigma for ppf
        sigma = (etak + (dgrho + 3 * adotoa / k * dgq) / 2._dl / k) / EV_kf1 - &
            k * Gamma
        sigma = sigma / adotoa

        S_Gamma = grhov_t * (1 + this%w_eff) * (vT + sigma) * k / adotoa / 2._dl / k2
        ckH = this%c_Gamma_ppf * k / adotoa
        Gammadot = S_Gamma / (1 + ckH * ckH) - Gamma - ckH * ckH * Gamma
        Gammadot = Gammadot * adotoa
        ayprime(w_ix) = Gammadot

        if (ckH * ckH .gt. 3.d1) then ! ckH^2 > 30 ?????????
            Gamma = 0
            Gammadot = 0.d0
            ayprime(w_ix) = Gammadot
        endif

        Fa = 1 + 3 * (grhoT + gpres) / 2._dl / k2 / EV_kf1
        dgqe = S_Gamma - Gammadot / adotoa - Gamma
        dgqe = -dgqe / Fa * 2._dl * k * adotoa + vT * grhov_t * (1 + this%w_eff)
        dgrhoe = -2 * k2 * EV_kf1 * Gamma - 3 / k * adotoa * dgqe
        dgrho = dgrho + dgrhoe
        dgq = dgq + dgqe

        this%dgrho_e_ppf = dgrhoe
        this%dgq_e_ppf = dgqe
    end if

    end subroutine TDarkEnergyPPF_DerivsAddPreSigma


    function TDarkEnergyPPF_DerivsAdd2Gpres(this, grhog_t, grhor_t, grhov_t) result(gpres)
    class(TDarkEnergyPPF), intent(in) :: this
    real(dl), intent(in) :: grhog_t, grhor_t, grhov_t
    real(dl) :: gpres

    gpres = grhov_t * this%w_eff

    end function TDarkEnergyPPF_DerivsAdd2Gpres


    end module DarkEnergyPPF