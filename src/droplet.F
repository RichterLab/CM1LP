  MODULE droplet_module

  implicit none

  private
  public :: droplet_driver,droplet_injection_driver,compute_droplet_substeps, &
            droplet_coalescence_driver,project_droplet_qc_effc, &
            droplet_diag,initialize_droplet_histograms, &
            check_droplet_ownership,particle_seed,ngidx, &
            kohler_equil_radius,lognormal_droplet

  !These are quantities which are needed in the droplet_diag output, so must be public
  real :: num100,num1000
  integer, parameter :: nbins = 130  !Bins for the droplet histograms
  real,dimension(nbins) :: bins_restime  !Bins for droplet residence time
  real,dimension(nbins,nbins) :: hist_restime  !Droplet residence time joint pdf (with size)
  real,dimension(nbins) :: bins_radius,hist_radius,hist_dry_radius,hist_radius10,hist_fallrad  !Histograms for droplet radius
  real :: restime_min,restime_max,restime_min10,restime_max10,dhres !Bin parameters for droplet residence time
  real :: dhrad,rmin,rmax,rmin10,rmax10  !Bin parameters for droplet size

  double precision :: u10_ssgf 
  double precision :: num_destroyed,num_injected,mass_destroyed,mass_injected !Cumulative particle counts between droplet_diag calls
  double precision :: eng_destroyed,eng_injected,m1_destroyed,m2_destroyed,m1_injected,m2_injected   !Same but for droplet internal energy and momentum
  double precision :: mass_reentry,eng_reentry,m1_reentry,m2_reentry
  double precision :: mass_evap,mass_dpten

  real, allocatable, dimension(:) :: sfs_fs_profile

  integer :: particle_seed

  integer :: ngidx  !Each MPI rank will keep a "global" particle index counter which increases for every new particle created on this rank

  ! If we already know that a parcel stays on the same process 
  !    in the previous time step and it is still here, we start 
  !    the location search from the previous index and limit 
  !    the search range using the parameter below;
  ! This assumes that a parcel does not move too far and does
  !    not move between processes within this subroutine?
  integer, parameter :: location_offset = 16

  !For testing: set this parameter to ".false." to make droplet injection deterministic (not random)
  logical, parameter :: random_droplets = .true.

  !$acc declare create (hist_restime,hist_radius,hist_dry_radius,hist_radius10, &
  !$acc                 hist_fallrad,restime_min,restime_max, &
  !$acc                 restime_min10,restime_max10,dhres,dhrad, &
  !$acc                 rmin,rmax,rmin10,rmax10,num_destroyed,mass_evap,mass_dpten, &
  !$acc                 num_injected,mass_destroyed,mass_injected, &
  !$acc                 mass_reentry,eng_reentry,m1_reentry,m2_reentry, &
  !$acc                 eng_destroyed,eng_injected,m1_destroyed,m2_destroyed,m1_injected,m2_injected, &
  !$acc                 num100,num1000,ngidx)

  CONTAINS

      subroutine droplet_driver (dt,dbldt,mtime,xh,uh,ruh,xf,yh,vh, &
                                 rvh,yf,zh,mh,rmh,zf,mf,zs,sigma, &
                                 sigmaf,znt,rho,ua,va,wa,s10,khh,khv, &
                                 tkea,dissten,pdata, &
                                 th_in,qa,th0,pi0,ppa,prs,ta,pw1,pw2, &
                                 pe1,pe2,ps1,ps2,pn1,pn2,nw1,nw2,ne1, &
                                 ne2,sw1,sw2,se1,se2,reqs_p,sw31,sw32, &
                                 se31,se32,ss31,ss32,sn31,sn32,n3w1, &
                                 n3w2,n3e1,n3e2,s3w1,s3w2,s3e1,s3e2, &
                                 reqs_s,dpten,pdata_locind,nstep,num_fallout_out)

      use input, only : ib,ie,jb,je,kb,ke,ibl,iel,jbl,jel,numq,ni,nj, &
          nk,nkp1,imp,jmp,kmp,rmp,cmp,kmt,npvals,npvars,cgs1,cgs2,cgs3, &
          cgt1,cgt2,cgt3,bbc,tbc,imove,zt,rzt,umove,vmove,nqv, &
          ibc,iec,jbc,jec,kbc,kec,ibt,iet,jbt,jet,kbt,ket, &
          terrain_flag,nx,ny,axisymm,nodex,nodey,myi,myj,viscosity, &
          prx,pry,prz,prsig,pract,prvpx,prvpy,prvpz,prtp,prrp,prmult, &
          prms,prkap,przs,pru,prv,prw,prt,prqv,prprs,prrho,prtime, &
          prpidx,prprocidx, &
          timestats,time_droplet,mytime,ierr,maxx, &
          maxy,maxz,ierr,mynw,mysw,myne,myse,mynorth,mysouth,myeast, &
          mywest,myid,nparcelsLocal,nparcelsLocalActive, &
          time_phys_H2D,time_phys_D2H,time_dropC1,time_dropC2,time_dropC3, &
          time_dropC4,ngxy,dx,dy,dz,testcase,drop_traj,drop_sgs_opt
      use constants
      use comm_module
      use comm_droplet_module
      use parcel_module
#ifdef MPI
      use mpi
#endif
      use MersenneTwister_mod
#ifdef _OPENACC
      use cutensorex
#endif

      implicit none

!-----------------------------------------------------------------------
!  This subroutine updates the parcel locations
!-----------------------------------------------------------------------

      real, intent(in) :: dt
      integer, intent(in) :: nstep
      integer, intent(out) :: num_fallout_out
      double precision, intent(in) :: dbldt
      double precision, intent(in) :: mtime
      real, intent(in), dimension(ib:ie) :: xh,uh,ruh
      real, intent(in), dimension(ib:ie+1) :: xf
      real, intent(in), dimension(jb:je) :: yh,vh,rvh
      real, intent(in), dimension(jb:je+1) :: yf
      real, intent(in), dimension(ib:ie,jb:je,kb:ke) :: zh
      real, intent(in), dimension(ib:ie,jb:je,kb:ke) :: mh,rmh
      real, intent(in), dimension(ib:ie,jb:je,kb:ke+1) :: zf,mf
      real, intent(in), dimension(ib:ie,jb:je) :: zs
      real, intent(in), dimension(kb:ke) :: sigma
      real, intent(in), dimension(kb:ke+1) :: sigmaf
      real, intent(in), dimension(ib:ie,jb:je) :: znt
      real, intent(in), dimension(ibl:iel,jbl:jel) :: s10
      real, intent(inout), dimension(ib:ie,jb:je,kb:ke) :: rho,prs,ta
      real, intent(inout), dimension(ib:ie,jb:je,kb:ke) :: pi0,th0,th_in,ppa
      double precision, intent(inout), dimension(ib:ie,jb:je,kb:ke,5) :: dpten
      real, intent(inout), dimension(ib:ie,jb:je,kb:ke,numq) :: qa
      real, intent(inout), dimension(ib:ie+1,jb:je,kb:ke) :: ua
      real, intent(inout), dimension(ib:ie,jb:je+1,kb:ke) :: va
      real, intent(inout), dimension(ib:ie,jb:je,kb:ke+1) :: wa
      real, intent(in), dimension(ibc:iec,jbc:jec,kbc:kec) :: khh,khv
      real, intent(in), dimension(ibt:iet,jbt:jet,kbt:ket) :: tkea
      real, intent(in), dimension(ib:ie,jb:je,kb:ke+1) :: dissten
      real, intent(inout), dimension(nparcelsLocal,npvals) :: pdata

      real, intent(inout), dimension(jmp,kmp) :: pw1,pw2,pe1,pe2
      real, intent(inout), dimension(imp,kmp) :: ps1,ps2,pn1,pn2
      real, intent(inout), dimension(kmt) :: nw1,nw2,ne1,ne2,sw1,sw2,se1,se2
      integer, intent(inout), dimension(rmp) :: reqs_p

      real, intent(inout), dimension(cmp,jmp,kmp)   :: sw31,sw32,se31,se32
      real, intent(inout), dimension(imp,cmp,kmp)   :: ss31,ss32,sn31,sn32
      real, intent(inout), dimension(cmp,cmp,kmt+1) :: n3w1,n3w2,n3e1,n3e2,s3w1,s3w2,s3e1,s3e2
      integer, intent(inout), dimension(rmp) :: reqs_s
      integer, intent(inout), dimension(nparcelsLocal,3) :: pdata_locind    ! x/y/z location index of each parcel

      !Need to compute the true temperature
!!!      real, dimension(ib:ie,jb:je,kb:ke) :: ta   ! GHB: now passed from solve3

      integer :: n,np,i,j,k,iflag,jflag,kflag
      integer :: pidx,procidx
      integer(i8) :: seed_base
      integer :: ix,iy,iz
      integer, dimension(2) :: numvec
      real :: x3d,y3d,z3d
      integer :: nrkp
      real :: dt2,uu1,vv1,ww1
      real :: sig3d,th_tmp,rand
      real :: dvpdt1,dvpdt2,dvpdt3,drpdt,dtpdt,dmpdt, &
              rp0,taup0,rhop0,x3d0,y3d0,z3d0,sig3d0

      real :: Nup,salinity,part_grav1,part_grav2,part_grav3
      real :: xv,yv,zv,dV,wtx,wty,wtz,wtt
      real :: esl

      double precision :: foot

      real :: uval,vval,wval,qval,prsval,tval,rhoval,rhval
      real :: khhval,khvval,dkhvdzval
      real :: sigsgsval,dsgsdxval,dsgsdyval,dsgsdzval,epssgsval,lsgsval,fsval
      real :: dlogsig_abs,dlogsig_max,dlogsig_mean
      real :: sigdot
      real :: fs_sgs(kb:ke+1)
      double precision :: dlogsig_sum

      logical, parameter :: debug = .false.

      type(randomNumberSequence) :: randomNumbers

      integer :: num_fallout,idx                        !droplets which fell out of domain
      integer :: dlogsig_valid,dlogsig_count
      integer :: dlogsig_gt05,dlogsig_gt1,dlogsig_gt2,dlogsig_gt5
      integer :: numDepart
      integer :: numDepartN, numDepartS, numDepartE, numDepartW, &
                 numDepartSW,numDepartSE,numDepartNE,numDepartNW
      integer, dimension(:), allocatable :: holes_fallout_ind  !their location index in pdata prior to removal

#ifdef MPI 
      integer, dimension(:), allocatable :: holes_ind      ! location index in "pdata" that can add a new droplet
      integer, dimension(:), allocatable :: Depart_ind     ! Index location in "pdata" of a point that is departing
      integer :: Depart(num_nn)                            ! Number of droplets that will enter each nearest 
                                                           ! neighbor at different directions
      integer :: Arrive(num_nn)                            ! Number of droplets that will enter the current
                                                           ! MPI region from each nearest neighbor
      integer :: ptrDepart(num_nn)                         ! Points to the begining of Depart_ind for various departure buffers
      integer :: ptrArrive(num_nn)                         ! Points to the begining of holes_ind for various arrival buffers
      integer, dimension(nparcelsLocal) :: pdata_neighbor  ! array to store the new MPI region info for all the droplets
#endif
      integer :: neighbor                                  ! indicate which MPI region a droplet stays after this time step 

      integer :: numHoles                                  ! total number of empty holes in pdata 
      integer :: numBackfill                               ! total number of droplets to backfill into "pdata" array holes
      integer :: numDepartAlloc,numHolesAlloc,numBackfillAlloc

      integer, dimension(:), allocatable :: backfill_ind   ! indicies of valid droplets to backfill into 
                                                           ! holes  in "pdata" array created by droplet 
                                                           ! fall-out or departure
#ifdef _OPENACC
      ! arrays used by count_prefix operator
      integer :: Cindx(nparcelsLocal)
      integer :: numHolesMask
      integer :: cidxMin,cidxMax,hidxMin,hidxMax
#endif
      logical :: msk(nparcelsLocal)

      logical, parameter :: verbose=.false.
      integer :: errcode
      integer(i8) :: nactive_new
      integer :: badActive, firstBad, lastBad
      integer :: badCompact, firstBadCompact, lastBadCompact
      integer :: numArrive_dbg, badArrive, firstBadArrive, lastBadArrive, indx
      integer :: badBackfillSearch, firstBadBackfill, lastBadBackfill, badThis
      integer :: badDepart, firstBadDepart, lastBadDepart
      integer :: badArriveHole, firstBadArriveHole, lastBadArriveHole
      integer :: badArriveN,badArriveS,badArriveW,badArriveE
      integer :: badArriveNW,badArriveNE,badArriveSW,badArriveSE
      integer :: arrN0,arrN1,arrS0,arrS1,arrW0,arrW1,arrE0,arrE1
      integer :: arrNW0,arrNW1,arrNE0,arrNE1,arrSW0,arrSW1,arrSE0,arrSE1
      ! 1) To match the initial and restart runs for total droplet number,
      !    use the following form to calculate the seed value so that it is 
      !    deterministic but varies between different MPI ranks and time steps
      ! 2) Otherwise, use David's original form with date and time to achieve
      !    more randomness but unmatched results between initial and restart runs

      particle_seed = int(mtime) * 1000 + myid
      call new_RandomNumberSequence(randomNumbers, particle_seed)

      num_fallout = 0  !Reset the number of droplets that have fallen out of physical domain
      errcode     = 0  ! Number of errors that occurred in the index search 
      numDepartN  = 0
      numDepartS  = 0
      numDepartE  = 0
      numDepartW  = 0
      numDepartNW = 0
      numDepartNE = 0
      numDepartSW = 0
      numDepartSE = 0

!----------------------------------------------------------------------
!  apply bottom/top boundary conditions:
!  [Note:  for u,v the array index (i,j,0) means the surface, ie z=0]
!     (for the parcel subroutines only!)

#ifdef MPI
      !$acc data create(pdata_neighbor,msk,fs_sgs)

      !$acc parallel loop gang vector default(present)
      do np = 1, nparcelsLocalActive
         pdata_neighbor(np) = undefined_index
      end do
      !$acc end parallel
#else
      !$acc data copyin (randomNumbers,randomNumbers%state) create(fs_sgs)
#endif

    IF(bbc.eq.1)THEN
      ! free slip ... extrapolate:
      !$acc parallel loop gang vector collapse(2) default(present)
      do j=jb,je
         do i=ib,ie+1
            ua(i,j,0) = cgs1*ua(i,j,1)+cgs2*ua(i,j,2)+cgs3*ua(i,j,3)
         end do
      end do
      !$acc end parallel
      !$acc parallel loop gang vector collapse(2) default(present)
      do j=jb,je+1
         do i=ib,ie
            va(i,j,0) = cgs1*va(i,j,1)+cgs2*va(i,j,2)+cgs3*va(i,j,3)
         end do
      end do
      !$acc end parallel
    ELSEIF(bbc.eq.2)THEN
      ! no slip:
      if( imove.eq.1 )then
        !$acc parallel loop gang vector collapse(2) default(present)
        do j=jb,je
           do i=ib,ie+1
              ua(i,j,0) = 0.0 - umove
           end do
        end do
        !$acc end parallel
        !$acc parallel loop gang vector collapse(2) default(present)
        do j=jb,je+1
           do i=ib,ie
              va(i,j,0) = 0.0 - vmove
           end do
        end do
        !$acc end parallel
      else
        !$acc parallel loop gang vector collapse(2) default(present)
        do j=jb,je
           do i=ib,ie+1
              ua(i,j,0) = 0.0
           end do
        end do
        !$acc end parallel
        !$acc parallel loop gang vector collapse(2) default(present)
        do j=jb,je+1
           do i=ib,ie
              va(i,j,0) = 0.0
           end do
        end do
        !$acc end parallel
      endif
    ELSEIF(bbc.eq.3)THEN
      ! u,v near sfc are determined below using log-layer equations
    ENDIF

!----------

    IF(tbc.eq.1)THEN
      ! free slip ... extrapolate:
      !$acc parallel loop gang vector collapse(2) default(present)
      do j=jb,je
         do i=ib,ie+1
            ua(i,j,nk+1) = cgt1*ua(i,j,nk)+cgt2*ua(i,j,nk-1)+cgt3*ua(i,j,nk-2)
         end do
      end do
      !$acc end parallel
      !$acc parallel loop gang vector collapse(2) default(present)
      do j=jb,je+1
         do i=ib,ie
            va(i,j,nk+1) = cgt1*va(i,j,nk)+cgt2*va(i,j,nk-1)+cgt3*va(i,j,nk-2)
         end do
      end do
      !$acc end parallel
    ELSEIF(tbc.eq.2)THEN
      ! no slip:
      !$acc parallel loop gang vector collapse(2) default(present)
      do j=jb,je
         do i=ib,ie+1
            ua(i,j,nk+1) = 0.0
         end do
      end do
      !$acc end parallel
      !$acc parallel loop gang vector collapse(2) default(present)
      do j=jb,je+1
         do i=ib,ie
            va(i,j,nk+1) = 0.0
         end do
      end do
      !$acc end parallel
    ENDIF

!----------

    !$acc parallel loop gang vector collapse(2) default(present)
    do j=jb,je
       do i=ib,ie
          wa(i,j,nk+1) = 0.0
       end do
    end do
    !$acc end parallel

    if (drop_sgs_opt.eq.2) then
       call compute_sfs_fs_profile(ua,va,wa,tkea,fs_sgs)
    else
       do k=kb,ke+1
          fs_sgs(k) = 0.0
       enddo
       if (allocated(sfs_fs_profile)) sfs_fs_profile = 0.0
    endif
    !$acc update device(fs_sgs)

  !Compute temperature for interpolation

  !$acc parallel default(present) private(i,j,k)
  !$acc loop gang vector collapse(3)
  do k=kb,ke
    do j=jb,je
    do i=ib,ie

      !th_tmp = (th0(i,j,k)+th_in(i,j,k))
      !ta(i,j,k) = th_tmp*(pi0(i,j,k)+ppa(i,j,k))
      ta(i,j,k) = (th0(i,j,k)+th_in(i,j,k))*(pi0(i,j,k)+ppa(i,j,k))

    enddo
    enddo
  enddo
  !$acc end parallel

  ! GHB 210714:
    call prepcorners3( ta,sw31,sw32,se31,se32,ss31,ss32,sn31,sn32,  &
                          n3w1,n3w2,n3e1,n3e2,s3w1,s3w2,s3e1,s3e2,reqs_s,1)
    call prepcorners3(rho,sw31,sw32,se31,se32,ss31,ss32,sn31,sn32,  &
                          n3w1,n3w2,n3e1,n3e2,s3w1,s3w2,s3e1,s3e2,reqs_s,1)
    call prepcorners3(prs,sw31,sw32,se31,se32,ss31,ss32,sn31,sn32,  &
                          n3w1,n3w2,n3e1,n3e2,s3w1,s3w2,s3e1,s3e2,reqs_s,1)
    call prepcorners3(qa(ib,jb,kb,nqv),sw31,sw32,se31,se32,ss31,ss32,sn31,sn32,  &
                          n3w1,n3w2,n3e1,n3e2,s3w1,s3w2,s3e1,s3e2,reqs_s,1)

!----------------------------------------------------------------------
!  Loop through all parcels:  if you have it, update it's properties

    dt2 = dt/2.0
    part_grav1 = 0.0
    part_grav2 = 0.0
    part_grav3 = -9.81

    !For Pi chamber, this is often scaled to some other value
    if (testcase.eq.16) then
       part_grav3 = -2.3122
    end if


    !Before entering the droplet update loop, save droplet trajectories

    if (drop_traj.eq.1) then
       call write_drop_traj(nstep,real(mtime),pdata)
    end if

    dlogsig_sum = 0.0d0
    dlogsig_max = 0.0
    dlogsig_count = 0
    dlogsig_gt05 = 0
    dlogsig_gt1 = 0
    dlogsig_gt2 = 0
    dlogsig_gt5 = 0

    !JMD WARNING: Loop does not yet match CPU version.
    !$acc parallel default(present)
    !$acc loop gang vector private(dlogsig_abs,dlogsig_valid) reduction(+:num_fallout) reduction(max:errcode) &
    !$acc reduction(+:dlogsig_sum,dlogsig_count,dlogsig_gt05,dlogsig_gt1,dlogsig_gt2,dlogsig_gt5) &
    !$acc reduction(max:dlogsig_max) &
    !$acc reduction(+:numDepartN,numDepartS,numDepartE,numDepartW) &
    !$acc reduction(+:numDepartNW,numDepartSW,numDepartNE,numDepartSE) &
    !$acc reduction(+:num_destroyed,mass_destroyed,mass_evap,mass_dpten,eng_destroyed,m1_destroyed,m2_destroyed,mass_reentry,eng_reentry,m1_reentry,m2_reentry)
    nploop:  &
    DO np=1,nparcelsLocalActive
      if (pdata(np,prrp).le.0.0 .or. pdata(np,prmult).le.0.0 .or. &
          pdata(np,pract).lt.0.0) then
        errcode = max(errcode,54323)
      endif


      x3d = pdata(np,prx)
      y3d = pdata(np,pry)
      if( .not. terrain_flag )then
        z3d = pdata(np,prz)
      else
        sig3d = pdata(np,prsig)
      endif

      iflag = undefined_index
      jflag = undefined_index
      kflag = 0

      IF(nx.eq.1)THEN
        iflag = 1
      ELSE
        ! cm1r19:
        call find_horizontal_location_index (pdata_locind(np,1), x3d, ib, ie+1, xf, ni+1, iflag) 
      ENDIF
  
      IF(axisymm.eq.1.or.ny.eq.1)THEN
        jflag = 1
      ELSE
        ! cm1r19:
        call find_horizontal_location_index (pdata_locind(np,2), y3d, jb, je+1, yf, nj+1, jflag)  
      ENDIF

#ifdef MPI
! JS: comment out this conflict check for the new MPI interface;
!     otherwise there will be a droplet leak

      ! check for conflict:
!    IF( (iflag.ge.1.and.iflag.le.ni) .and.   &
!        (jflag.ge.1.and.jflag.le.nj) )THEN
!      IF( iflag.eq.ni .and. pdata(np,prx).eq.xf(iflag+1) .and. nodex.gt.1 .and.  myi.ne.nodex ) iflag = -1
!      IF( jflag.eq.nj .and. pdata(np,pry).eq.yf(jflag+1) .and. nodey.gt.1 .and.  myj.ne.nodey ) jflag = -1
!    ENDIF
#endif

      kflag = 1
      if( .not. terrain_flag )then
        !JS-KLUDGE: Somehow I have to use the zf_tmp variable 
        !           for the find_vertical* subroutine,
        !           otherwise the GPU code breaks for nparcels > ~2000
!        !$acc loop seq
!        do k = kb, ke+1
!           zf_tmp(k) = zf(iflag,jflag,k)
!        end do
         do while( z3d.gt.zf(iflag,jflag,kflag+1) )
            kflag = kflag+1
         enddo
         pdata_locind(np,3) = kflag
!         call find_vertical_location_index (pdata_locind(np,3), z3d, kb, ke+1, zf_tmp, kflag, .TRUE.)
      else
         call find_vertical_location_index (pdata_locind(np,3), sig3d, kb, ke+1, sigmaf, kflag, .TRUE.)
      endif

      dvpdt1 = pdata(np,prvpx)
      dvpdt2 = pdata(np,prvpy)
      dvpdt3 = pdata(np,prvpz)
      dtpdt  = pdata(np,prtp)
      drpdt  = pdata(np,prrp)
      dmpdt  = rhow*4.0/3.0*pi*pdata(np,prrp)**3
      
      !Store its old position before getting updated:
      x3d0   = x3d
      y3d0   = y3d
      z3d0   = z3d 
      sig3d0 = sig3d

      call interpolate_to_parcel(np,iflag,jflag,kflag,x3d,y3d,z3d,sig3d, &
                                 uval,vval,wval,tval,qval,rhoval,prsval, &
                                 xh,xf,yh,yf,zh,zf,zs,znt,sigma,sigmaf, &
                                 ua,va,wa,ta,qa,rho,prs,sigdot)

      khhval = 0.0
      khvval = 0.0
      dkhvdzval = 0.0
      sigsgsval = 0.0
      dsgsdxval = 0.0
      dsgsdyval = 0.0
      dsgsdzval = 0.0
      epssgsval = 0.0
      lsgsval = 0.0
      fsval = 0.0
      if (drop_sgs_opt.eq.1) then
        call interpolate_sfs_position_fields(iflag,jflag,kflag,x3d,y3d,z3d,sig3d, &
                                             khhval,khvval,dkhvdzval, &
                                             xh,yh,zf,sigmaf,khh,khv)
      endif
      if (drop_sgs_opt.eq.2) then
        call interpolate_sfs_velocity_fields(iflag,jflag,kflag,x3d,y3d,z3d,sig3d, &
                                             sigsgsval,dsgsdxval,dsgsdyval,dsgsdzval, &
                                             epssgsval,lsgsval,fsval, &
                                             xh,yh,zf,sigmaf,tkea,dissten,fs_sgs)
      endif

      ! NVHPC 23.1 cannot lower TRANSFER inside acc routine seq.
      pidx = transfer(pdata(np,prpidx),0)
      procidx = transfer(pdata(np,prprocidx),0)
      seed_base = mod(abs(int(pidx,i8))*1000003_i8,2147483647_i8)
      seed_base = mod(seed_base + abs(int(procidx,i8))*9176_i8,2147483647_i8)

      call BE_integration (dt,dbldt,nstep,mtime,np,seed_base,pdata,pdata_locind,xf,yf,zf, &
                           iflag,jflag, &
                           x3d,y3d,z3d,sig3d,uval,vval,wval,qval, &
                           khhval,khvval,dkhvdzval, &
                           sigsgsval,dsgsdxval,dsgsdyval,dsgsdzval, &
                           epssgsval,lsgsval,fsval, &
                           rhoval,prsval,tval,Nup,rhop0,taup0,rp0, &
                           part_grav1,part_grav2,part_grav3,debug, &
                           dlogsig_abs,dlogsig_valid,neighbor,num_fallout,errcode)
      if (dlogsig_valid.eq.1) then
         dlogsig_sum = dlogsig_sum + dble(dlogsig_abs)
         dlogsig_max = max(dlogsig_max,dlogsig_abs)
         dlogsig_count = dlogsig_count + 1
         if (dlogsig_abs.gt.0.5) dlogsig_gt05 = dlogsig_gt05 + 1
         if (dlogsig_abs.gt.1.0) dlogsig_gt1 = dlogsig_gt1 + 1
         if (dlogsig_abs.gt.2.0) dlogsig_gt2 = dlogsig_gt2 + 1
         if (dlogsig_abs.gt.5.0) dlogsig_gt5 = dlogsig_gt5 + 1
      endif

#ifdef MPI
      if(neighbor .eq. mynorth) then 
         pdata_neighbor(np) = inorth
         numDepartN=numDepartN+1
      else if(neighbor .eq. mysouth) then 
         pdata_neighbor(np) = isouth
         numDepartS=numDepartS+1
      else if(neighbor .eq. mywest) then 
         pdata_neighbor(np) = iwest
         numDepartW=numDepartW+1
      else if(neighbor .eq. myeast) then 
         pdata_neighbor(np) = ieast
         numDepartE=numDepartE+1
      else if(neighbor .eq. mynw) then 
         pdata_neighbor(np) = inw
         numDepartNW=numDepartNW+1
      else if(neighbor .eq. myne) then 
         pdata_neighbor(np) = ine
         numDepartNE=numDepartNE+1
      else if(neighbor .eq. mysw) then 
         pdata_neighbor(np) = isw
         numDepartSW=numDepartSW+1
      else if(neighbor .eq. myse) then 
         pdata_neighbor(np) = ise
         numDepartSE=numDepartSE+1
      endif
#endif

!-----------------------------------------------------
!  Now perform the two-way coupling based on the changes in droplet momentum,
!  temp, and size
!-----------------------------------------------------

      !Recall that the "old" values are stored in the "d/dt" variables
      dvpdt1 = (pdata(np,prvpx)-dvpdt1)/dt   !Remember to deal with gravity later!
      dvpdt2 = (pdata(np,prvpy)-dvpdt2)/dt
      dvpdt3 = (pdata(np,prvpz)-dvpdt3)/dt
      drpdt  = (pdata(np,prrp)-drpdt)/dt
      dtpdt  = (pdata(np,prtp)-dtpdt)/dt
      dmpdt  = (rhow*4.0/3.0*pi*pdata(np,prrp)**3-dmpdt)/dt

      mass_evap = mass_evap + dmpdt*dt*pdata(np,prmult)


      !Project the feedback onto the grid, using ORIGINAL location
      call project_feedback(iflag,jflag,kflag,x3d0,y3d0,z3d0,sig3d0, &
                            rhop0,taup0,rp0,tval,dpten, &
                            xh,xf,yh,yf,zh,zf,sigma,sigmaf, &
                            sigdot,dvpdt1,dvpdt2,dvpdt3,drpdt,dtpdt,dmpdt, &
                            rhoval,part_grav1,part_grav2,part_grav3,pdata,np)

    END DO nploop
    !$acc end parallel
    !$acc wait
    if (drop_sgs_opt.eq.2) then
#ifdef MPI
       call mpi_allreduce(mpi_in_place,dlogsig_sum,1,mpi_double_precision,mpi_sum,mpi_comm_world,ierr)
       call mpi_allreduce(mpi_in_place,dlogsig_max,1,mpi_real,mpi_max,mpi_comm_world,ierr)
       call mpi_allreduce(mpi_in_place,dlogsig_count,1,mpi_integer,mpi_sum,mpi_comm_world,ierr)
       call mpi_allreduce(mpi_in_place,dlogsig_gt05,1,mpi_integer,mpi_sum,mpi_comm_world,ierr)
       call mpi_allreduce(mpi_in_place,dlogsig_gt1,1,mpi_integer,mpi_sum,mpi_comm_world,ierr)
       call mpi_allreduce(mpi_in_place,dlogsig_gt2,1,mpi_integer,mpi_sum,mpi_comm_world,ierr)
       call mpi_allreduce(mpi_in_place,dlogsig_gt5,1,mpi_integer,mpi_sum,mpi_comm_world,ierr)
#endif
       if (dlogsig_count.gt.0) then
          dlogsig_mean = real(dlogsig_sum/dble(dlogsig_count))
       else
          dlogsig_mean = 0.0
       endif
       if (myid.eq.0) then
          write(*,'(a,i8,a,f12.4,a,1pe12.4,a,1pe12.4,a,i12,a,i12,a,i12,a,i12,a,i12)') &
               'SGS_DLOGSIG nstep=',nstep,' mtime=',real(mtime),' mean=',dlogsig_mean, &
               ' max=',dlogsig_max,' n=',dlogsig_count,' n0p5=',dlogsig_gt05, &
               ' n1=',dlogsig_gt1,' n2=',dlogsig_gt2,' n5=',dlogsig_gt5
          call flush(6)
       endif
    endif
    if (errcode .gt. 0) then 
       stop 'FATAL error occurred in the index search BE_integration'
    end if


    !$acc parallel default(present) private(i,j,k) reduction(+:foot,mass_dpten)
    !$acc loop gang reduction(+:mass_dpten)
    do k=1,nk
      foot = 0.0d0
      !$acc loop vector collapse(2) reduction(+:foot)
      do j=1,nj
      do i=1,ni
        foot=foot + rho(i,j,k)*dpten(i,j,k,2)*ruh(i)*rvh(j)*rmh(i,j,k)*dt*(dx*dy*dz)
      enddo
      enddo
      mass_dpten=mass_dpten+foot
    enddo
    !$acc end parallel


    !$acc parallel default(present)
    !$acc loop gang vector collapse(3)
    do k=kb,ke
       do j=jb,je
          do i=ib,ie
             dpten(i,j,k,1) = dpten(i,j,k,1)*pi0(i,j,k)
          end do
       end do
    end do
    !$acc end parallel   
    if(timestats.ge.1) time_droplet=time_droplet+mytime()

    Depart(inorth) = numDepartN
    Depart(isouth) = numDepartS
    Depart(ieast)  = numDepartE
    Depart(iwest)  = numDepartW
    Depart(inw)    = numDepartNW
    Depart(ine)    = numDepartNE
    Depart(isw)    = numDepartSW
    Depart(ise)    = numDepartSE

    numDepart=SUM(Depart)
    numDepartAlloc = max(1,numDepart)
    allocate(Depart_ind(numDepartAlloc))
    !$acc enter data create(Depart_ind)

    numHoles = numDepart + num_fallout + (nparcelsLocal-nparcelsLocalActive)
    numHolesAlloc = max(1,numHoles)

!----------------------------------------------------------------------
!  communicate data  (for MPI runs)
!  note Step 1 is also needed for a non-MPI run

     ! JS: send/receive the droplet information through MPI;
     !     all the calculations below are done on CPU

     !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
     ! Step 1: Allocate and assign the "hole" index array and initialize it !
     !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

     allocate(holes_ind(numHolesAlloc))
     !$acc enter data create(holes_ind)

     !$acc parallel loop gang vector default(present) 
     do np=1,nparcelsLocal
       msk(np) = (pdata_locind(np,1) .eq. undefined_index) .and. &
                 (pdata_locind(np,2) .eq. undefined_index)
     enddo

#ifdef _OPENACC
     numHolesMask = 0
     !$acc parallel loop gang vector default(present) reduction(+:numHolesMask)
     do np=1,nparcelsLocal
       if(msk(np)) numHolesMask = numHolesMask + 1
     enddo
     !$acc end parallel

     if(numHolesMask .ne. numHoles) then
       stop 'DROPLET HOLE MISMATCH'
     endif

     !$acc data create(Cindx)

     !$acc parallel loop gang vector default(present)
     do np = 1, numHoles
       holes_ind(np) = undefined_index
     end do
     !$acc end parallel

     ! Use a CUDA-based function count_prefix determins which array
     ! elements satisfy a particular condition.  For example consider
     ! locind = [1 2 3 4 undefined 5 6 7 undefined 8]
     ! C = COUNT_PREFIX(mask = (locind .eq. undefined), EXCLUSIVE=.true.)
     ! would generate the array 
     ! C = [0 0 0 0 0 1 1 1 1 2]
     !$acc wait
     Cindx = count_prefix(mask=msk,exclusive=.true.)
     !$acc wait

     cidxMin = huge(1)
     cidxMax = -huge(1)
     hidxMin = huge(1)
     hidxMax = -huge(1)

     !$acc parallel loop gang vector default(present) &
     !$acc reduction(min:cidxMin,hidxMin) reduction(max:cidxMax,hidxMax)
     do np=1,nparcelsLocal
       cidxMin = min(cidxMin,Cindx(np))
       cidxMax = max(cidxMax,Cindx(np))
       if (np.lt.nparcelsLocal) then
         if(Cindx(np) .ne. Cindx(np+1)) then
           hidxMin = min(hidxMin,Cindx(np)+1)
           hidxMax = max(hidxMax,Cindx(np)+1)
         endif
       elseif (msk(np)) then
         hidxMin = min(hidxMin,Cindx(np)+1)
         hidxMax = max(hidxMax,Cindx(np)+1)
       endif
     enddo
     !$acc end parallel

     if(cidxMin.lt.0 .or. cidxMax.gt.numHoles .or. &
        hidxMin.lt.1 .or. hidxMax.gt.numHoles) then
       stop 'DROPLET CINDX BAD'
     endif

     ! collect the location of the special values into a smaller array
     !$acc parallel loop gang vector present(Cindx(1:nparcelsLocal),holes_ind(1:numHolesAlloc))
     do np = 1, nparcelsLocal-1
        if ( Cindx(np) .ne. Cindx(np+1) ) then 
           holes_ind(Cindx(np)+1) = np
        end if
     end do
     !$acc end parallel

     ! Special treatment for the last value in the array
     !$acc serial present(msk(1:nparcelsLocal),Cindx(1:nparcelsLocal),holes_ind(1:numHolesAlloc))
     if(msk(nparcelsLocal)) then
       holes_ind(Cindx(nparcelsLocal)+1) = nparcelsLocal
     endif
     !$acc end serial

     !$acc end data

#else
     !CPU based calculations 
     do np = 1, numHoles
       holes_ind(np) = undefined_index
     end do

     i=0
     do np = 1, nparcelsLocal
       if (msk(np)) then 
          i = i + 1
          holes_ind(i) = np
       end if
     end do
     !$acc update device(holes_ind)
#endif

     if(timestats.ge.1) time_dropC1=time_dropC1+mytime()

     !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
     ! Step 2: Setup the indirect addresses for the droplets that are departing !
     !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

     ! On the CPU, assign pointers (ptrDepart) into indirect address 
     ! array (Depart_ind) for deprting droplets
     call setupIndexPointers(Depart,ptrDepart)

     ! On the CPU, assign the indirect address array (Depart_ind)
     ! for departing droplets
     call setupDepartDroplet(Depart_ind,ptrDepart,Depart,pdata_neighbor)

     if(timestats.ge.1) time_dropC2=time_dropC2+mytime()

#ifdef MPI
    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    ! Step 3: Exchange the number of droplets that will enter/leave !
    !         the current MPI region with its nearest neighbor      !
    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

    ! On the CPU determine the number of arriving droplet
    call comm_droplet_number(numHoles,Depart,Arrive)
    !$acc wait

    
    ! On the CPU assigns pointers (ptrArrive) into indirect address 
    ! array (holes_ind) for arriving droplets
    call setupIndexPointers(Arrive,ptrArrive)

    nactive_new = nparcelsLocalActive + sum(Arrive) - sum(Depart) - num_fallout
    numArrive_dbg = sum(Arrive)

    ! Only holes inside the new active prefix need donor backfill.
    ! Holes above nactive_new become inactive tail slots.
    numBackfill = 0
#ifdef _OPENACC
    !$acc parallel loop gang vector default(present) reduction(+:numBackfill)
#endif
    do n = numArrive_dbg + 1, numHoles
      if (int(holes_ind(n),i8) .le. nactive_new) then
        numBackfill = numBackfill + 1
      endif
    enddo
#ifdef _OPENACC
    !$acc end parallel
#endif
    !$acc wait

    if (nactive_new .lt. 0_i8 .or. &
        nactive_new .gt. int(nparcelsLocal,i8) .or. &
        int(numBackfill,i8) .gt. nparcelsLocalActive) then
      stop 'DROPLET BAD BACKFILL COUNTS'
    endif

    numBackfillAlloc = max(1,numBackfill)
     ! Determine which droplets to relocated from the end of 
     ! the "pdata" array to the remaining holes
     allocate(backfill_ind(numBackfillAlloc))
     !$acc enter data create(backfill_ind)
     badBackfillSearch = 0
     if (numBackfill .gt. 0) then 
       !$acc parallel num_gangs(1) num_workers(1) default(present)
       np = nparcelsLocalActive
       i=0
       do while (i.lt. numBackfill)
         do while (np.gt.0)
           if (int(np,i8).gt.nactive_new .and. .not.msk(np)) exit
           np=np-1
         enddo
         i=i+1
         if (np.gt.0) then
           backfill_ind(i) = np
           np=np-1
         else
           backfill_ind(i) = nparcelsLocalActive+1
         endif
       enddo
       !$acc end parallel
       if(verbose) then
          !$acc update host(backfill_ind)
          print *,'backfill_ind: ',backfill_ind(1:numBackfill)
       endif
     end if

     if (numBackfill .gt. 0) then
       badBackfillSearch = 0
       firstBadBackfill = numBackfill + 1
       lastBadBackfill = 0
       !$acc parallel loop gang vector default(present) private(k) &
       !$acc reduction(+:badBackfillSearch) &
       !$acc reduction(min:firstBadBackfill) reduction(max:lastBadBackfill)
       do n=1,numBackfill
         k = backfill_ind(n)
         if (k .lt. 1 .or. k .gt. nparcelsLocalActive .or. &
             int(k,i8) .le. nactive_new) then
           badBackfillSearch = badBackfillSearch + 1
           firstBadBackfill = min(firstBadBackfill,n)
           lastBadBackfill = max(lastBadBackfill,n)
         endif
       enddo
       !$acc end parallel
     endif

     !$acc wait

     if (badBackfillSearch .gt. 0) then
       !$acc update host(backfill_ind)
       print *,'DROPLET BACKFILL SEARCH EXHAUSTED DETAIL myid=',myid, &
               ' nstep=',nstep
       print *,' active_old=',nparcelsLocalActive,' active_new=', &
               nactive_new,' depart=',sum(Depart),' fallout=',num_fallout
       print *,' arrive=',sum(Arrive),' backfill=',numBackfill, &
               ' bad_donors=',badBackfillSearch
       print *,' first_bad_backfill=',firstBadBackfill, &
               ' last_bad_backfill=',lastBadBackfill
       if (firstBadBackfill.ge.1 .and. firstBadBackfill.le.numBackfill) then
         print *,' first_bad_donor=',backfill_ind(firstBadBackfill)
       endif
       call flush(6)
       stop 'DROPLET BACKFILL SEARCH EXHAUSTED'
     endif

    if(verbose) then 
      write(*,'(f10.3,a6,i4,a8,8i6)') mtime, ' myid: ', myid, ' Depart: ', Depart
      write(*,'(f10.3,a6,i4,a8,8i6)') mtime, ' myid: ', myid, ' Arrive: ', Arrive
      call flush(6)
    endif

    if(timestats.ge.1) time_dropC3=time_dropC3+mytime()

    badArriveHole = 0
    firstBadArriveHole = numArrive_dbg + 1
    lastBadArriveHole = 0
    if (numArrive_dbg.gt.0) then
      !$acc parallel loop gang vector default(present) private(indx,badThis) &
      !$acc reduction(+:badArriveHole) &
      !$acc reduction(min:firstBadArriveHole) reduction(max:lastBadArriveHole)
      do n=1,numArrive_dbg
        indx = holes_ind(n)
        badThis = 0
        if (indx .lt. 1 .or. indx .gt. nparcelsLocal) then
          badThis = 1
        else
          if (.not.msk(indx)) then
            badThis = 1
          endif
          if (n.gt.1) then
            if (holes_ind(n) .le. holes_ind(n-1)) then
              badThis = 1
            endif
          endif
        endif

        if (badThis.ne.0) then
          badArriveHole = badArriveHole + 1
          firstBadArriveHole = min(firstBadArriveHole,n)
          lastBadArriveHole = max(lastBadArriveHole,n)
        endif
      enddo
      !$acc end parallel
    endif

    if (badArriveHole.gt.0) then
      !$acc update host(holes_ind)
      print *,'DROPLET BAD ARRIVAL HOLE BEFORE COMM DETAIL myid=', &
              myid,' nstep=',nstep
      print *,' active_old=',nparcelsLocalActive,' active_new=', &
              nactive_new,' depart=',numDepart,' fallout=',num_fallout
      print *,' arrive=',numArrive_dbg,' backfill=',numBackfill, &
              ' bad_holes=',badArriveHole
      print *,' first_bad_arrival_hole=',firstBadArriveHole, &
              ' last_bad_arrival_hole=',lastBadArriveHole
      if (firstBadArriveHole.ge.1 .and. &
          firstBadArriveHole.le.numArrive_dbg) then
        print *,' first_bad_hole_index=',holes_ind(firstBadArriveHole)
      endif
      print *,' Depart=',Depart
      print *,' Arrive=',Arrive
      call flush(6)
      stop 'DROPLET BAD ARRIVAL HOLE BEFORE COMM'
    endif

    badDepart = 0
    firstBadDepart = numDepart + 1
    lastBadDepart = 0
    if (numDepart.gt.0) then
      !$acc parallel loop gang vector default(present) private(indx,badThis) &
      !$acc reduction(+:badDepart) &
      !$acc reduction(min:firstBadDepart) reduction(max:lastBadDepart)
      do n=1,numDepart
        indx = Depart_ind(n)
        badThis = 0
        if (indx .lt. 1 .or. indx .gt. nparcelsLocalActive) then
          badThis = 1
        else
          if (pdata(indx,prrp) .le. 0.0 .or. &
              pdata(indx,prmult) .le. 0.0 .or. &
              pdata(indx,pract) .lt. 0.0) then
            badThis = 1
          endif
        endif

        if (badThis.ne.0) then
          badDepart = badDepart + 1
          firstBadDepart = min(firstBadDepart,n)
          lastBadDepart = max(lastBadDepart,n)
        endif
      enddo
      !$acc end parallel
    endif

    if (badDepart.gt.0) then
      !$acc update host(Depart_ind)
      print *,'DROPLET BAD DEPARTURE BEFORE COMM DETAIL myid=', &
              myid,' nstep=',nstep
      print *,' active_old=',nparcelsLocalActive,' active_new=', &
              nactive_new,' depart=',numDepart,' fallout=',num_fallout
      print *,' arrive=',numArrive_dbg,' backfill=',numBackfill, &
              ' bad_depart=',badDepart
      print *,' first_bad_depart_slot=',firstBadDepart, &
              ' last_bad_depart_slot=',lastBadDepart
      if (firstBadDepart.ge.1 .and. firstBadDepart.le.numDepart) then
        print *,' first_bad_depart_index=',Depart_ind(firstBadDepart)
      endif
      print *,' Depart=',Depart
      print *,' Arrive=',Arrive
      call flush(6)
      stop 'DROPLET BAD DEPARTURE BEFORE COMM'
    endif

    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    ! Step 4: Exchange the detailed information of the droplets that will  !
    !         enter/leave the current MPI region with its nearest neighbor !
    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    ! Most of the indirect address arrays are calculated on the CPU.
    ! So copy them to the GPU

    ! On the GPU, move droplets between different MPI ranks.
    call comm_droplet_value(holes_ind,Depart_ind, Depart,Arrive, &
                            ptrDepart,ptrArrive, pdata)
    !$acc wait

    numArrive_dbg = sum(Arrive)
    nactive_new = nparcelsLocalActive + sum(Arrive) - sum(Depart) - num_fallout

    badArrive = 0
    badArriveN = 0
    badArriveS = 0
    badArriveW = 0
    badArriveE = 0
    badArriveNW = 0
    badArriveNE = 0
    badArriveSW = 0
    badArriveSE = 0
    firstBadArrive = numArrive_dbg + 1
    lastBadArrive = 0
    arrN0  = ptrArrive(inorth)
    arrN1  = arrN0  + Arrive(inorth)
    arrS0  = ptrArrive(isouth)
    arrS1  = arrS0  + Arrive(isouth)
    arrW0  = ptrArrive(iwest)
    arrW1  = arrW0  + Arrive(iwest)
    arrE0  = ptrArrive(ieast)
    arrE1  = arrE0  + Arrive(ieast)
    arrNW0 = ptrArrive(inw)
    arrNW1 = arrNW0 + Arrive(inw)
    arrNE0 = ptrArrive(ine)
    arrNE1 = arrNE0 + Arrive(ine)
    arrSW0 = ptrArrive(isw)
    arrSW1 = arrSW0 + Arrive(isw)
    arrSE0 = ptrArrive(ise)
    arrSE1 = arrSE0 + Arrive(ise)

    if (numArrive_dbg.gt.0) then
      !$acc parallel loop gang vector default(present) private(indx,badThis) &
      !$acc reduction(+:badArrive,badArriveN,badArriveS,badArriveW,badArriveE) &
      !$acc reduction(+:badArriveNW,badArriveNE,badArriveSW,badArriveSE) &
      !$acc reduction(min:firstBadArrive) reduction(max:lastBadArrive)
      do n=1,numArrive_dbg
        indx = holes_ind(n)
        badThis = 0

        if (indx .lt. 1 .or. indx .gt. nparcelsLocal) then
          badThis = 1
        else
          if (pdata(indx,prrp) .le. 0.0 .or. &
              pdata(indx,prmult) .le. 0.0 .or. &
              pdata(indx,pract) .lt. 0.0) then
            badThis = 1
          endif
        endif

        if (badThis .ne. 0) then
          badArrive = badArrive + 1
          firstBadArrive = min(firstBadArrive,n)
          lastBadArrive = max(lastBadArrive,n)
          if (n .ge. arrN0  .and. n .lt. arrN1)  badArriveN  = badArriveN  + 1
          if (n .ge. arrS0  .and. n .lt. arrS1)  badArriveS  = badArriveS  + 1
          if (n .ge. arrW0  .and. n .lt. arrW1)  badArriveW  = badArriveW  + 1
          if (n .ge. arrE0  .and. n .lt. arrE1)  badArriveE  = badArriveE  + 1
          if (n .ge. arrNW0 .and. n .lt. arrNW1) badArriveNW = badArriveNW + 1
          if (n .ge. arrNE0 .and. n .lt. arrNE1) badArriveNE = badArriveNE + 1
          if (n .ge. arrSW0 .and. n .lt. arrSW1) badArriveSW = badArriveSW + 1
          if (n .ge. arrSE0 .and. n .lt. arrSE1) badArriveSE = badArriveSE + 1
        endif
      enddo
      !$acc end parallel
    endif

    if (badArrive.gt.0) then
      !$acc update host(holes_ind)
      print *,'DROPLET BAD ARRIVAL AFTER COMM DETAIL myid=', &
              myid,' nstep=',nstep
      print *,' active_old=',nparcelsLocalActive,' active_new=', &
              nactive_new,' depart=',numDepart,' fallout=',num_fallout
      print *,' arrive=',numArrive_dbg,' backfill=',numBackfill, &
              ' bad_arrive=',badArrive
      print *,' bad_dirs N S W E NW NE SW SE=',badArriveN,badArriveS, &
              badArriveW,badArriveE,badArriveNW,badArriveNE, &
              badArriveSW,badArriveSE
      print *,' first_bad_arrive_slot=',firstBadArrive, &
              ' last_bad_arrive_slot=',lastBadArrive
      if (firstBadArrive.ge.1 .and. firstBadArrive.le.numArrive_dbg) then
        print *,' first_bad_arrive_hole=',holes_ind(firstBadArrive)
      endif
      print *,' Depart=',Depart
      print *,' Arrive=',Arrive
      call flush(6)
      stop 'DROPLET BAD ARRIVAL AFTER COMM'
    endif

    badCompact = 0
    firstBadCompact = numBackfill + 1
    lastBadCompact = 0

    if (numBackfill.gt.0) then
      !$acc parallel loop gang vector default(present) private(indx,k,badThis) &
      !$acc reduction(+:badCompact) &
      !$acc reduction(min:firstBadCompact) reduction(max:lastBadCompact)
      do n=1,numBackfill
        indx = holes_ind(numArrive_dbg+n)
        k = backfill_ind(n)
        badThis = 0

        if (indx .lt. 1 .or. indx .gt. nparcelsLocal) then
          badThis = 1
        elseif (int(indx,i8) .gt. nactive_new) then
          badThis = 1
        endif

        if (k .lt. 1 .or. k .gt. nparcelsLocalActive .or. &
            int(k,i8) .le. nactive_new) then
          badThis = 1
        else
          if (pdata(k,prrp) .le. 0.0 .or. &
              pdata(k,prmult) .le. 0.0 .or. &
              pdata(k,pract) .lt. 0.0) then
            badThis = 1
          endif
        endif

        if (badThis .ne. 0) then
          badCompact = badCompact + 1
          firstBadCompact = min(firstBadCompact,n)
          lastBadCompact = max(lastBadCompact,n)
        endif
      enddo
      !$acc end parallel
    end if

    if (badCompact.gt.0) then
      !$acc update host(holes_ind,backfill_ind)
      print *,'DROPLET BAD COMPACT INDEX DETAIL myid=',myid, &
              ' nstep=',nstep
      print *,' active_old=',nparcelsLocalActive,' active_new=', &
              nactive_new,' depart=',numDepart,' fallout=',num_fallout
      print *,' arrive=',numArrive_dbg,' backfill=',numBackfill, &
              ' bad_compact=',badCompact
      print *,' first_bad_compact=',firstBadCompact, &
              ' last_bad_compact=',lastBadCompact
      if (firstBadCompact.ge.1 .and. firstBadCompact.le.numBackfill) then
        print *,' first_bad_hole=',holes_ind(numArrive_dbg+firstBadCompact), &
                ' first_bad_donor=',backfill_ind(firstBadCompact)
      endif
      print *,' Depart=',Depart
      print *,' Arrive=',Arrive
      call flush(6)
      stop 'DROPLET BAD COMPACT INDEX'
    endif

    ! On the GPU, compress the new "pdata" to make sure that all the active
    !     droplets are contiguous (no "holes" between "pdata" slots)
    call makeContiguous(Depart,Arrive,num_fallout,numBackfill, &
                         holes_ind,backfill_ind,pdata,pdata_locind)
    !$acc wait

    nactive_new = nparcelsLocalActive + sum(Arrive) - sum(Depart) - num_fallout

    badActive = 0
    firstBad = nparcelsLocal + 1
    lastBad = 0

    !$acc parallel loop gang vector default(present) &
    !$acc reduction(+:badActive) reduction(min:firstBad) reduction(max:lastBad)
    do np=1,nactive_new
      if (pdata(np,prrp).le.0.0 .or. pdata(np,prmult).le.0.0 .or. &
          pdata(np,pract).lt.0.0) then
        badActive = badActive + 1
        firstBad = min(firstBad,np)
        lastBad = max(lastBad,np)
      endif
    enddo
    !$acc end parallel

    if (badActive.gt.0) then
      stop 'DROPLET BAD AFTER COMPACT'
    endif

    nparcelsLocalActive = nactive_new


    if(timestats.ge.1) time_dropC4=time_dropC4+mytime()

    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    ! Step 5: Update the count of new active droplets with contiguous memory !
    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

#else

!----------------------------------------------------------------------
!  remove the "holes" due to droplets which fell out: collapse pdata and adjust nparcelsLocalActive
!  num_fallout already contains the number which have fallen out

   !Now transfer these to the end of the pdata list
   !Simply move the last particle in the list, pdata(nparcelsLocalActive,:), to a hole and update nparcelsLocalActive

   ! JS: need to gpu-enable the following code section for a non-MPI run
   do np=numHoles,1,-1
      if (holes_ind(np) .eq. nparcelsLocalActive) then
         nparcelsLocalActive = nparcelsLocalActive-1  !If the dead particle is at end, simply reduce nparcelsLocalActive
      else
         pdata(holes_ind(np),:) = pdata(nparcelsLocalActive,:)
         pdata_locind(holes_ind(np),:) = pdata_locind(nparcelsLocalActive,:)
         pdata_neighbor(holes_ind(np)) = pdata_neighbor(nparcelsLocalActive)
         nparcelsLocalActive = nparcelslocalActive-1
      end if
      ! reset all the information for this "dead" droplet
      pdata_locind(nparcelsLocalActive+1,:) = undefined_index
      pdata(nparcelsLocalActive+1,:) = neg_huge
      pdata_neighbor(nparcelsLocalActive+1) = undefined_index
   end do

    if(timestats.ge.1) time_droplet=time_droplet+mytime()

#endif
!$acc end data ! (pdata_neighbr,msk)

    ! free up the memory for temporary variables

     !$acc exit data delete(holes_ind)
     deallocate(holes_ind)

     if(allocated(Depart_ind)) then 
        !$acc exit data delete(Depart_ind)
        deallocate(Depart_ind)
     endif

     if(allocated(backfill_ind)) then 
        !$acc exit data delete(backfill_ind)
        deallocate(backfill_ind)
     endif

!----------------------------------------------------------------------
!  get height ASL:

    if ( terrain_flag ) then
#ifdef _OPENACC
       print *,'WARNING: entering code that has not been ported to OpenACC'
#endif
       call getparcelzs(xh,uh,ruh,xf,yh,vh,rvh,yf,zs,pdata)
       DO np=1,nparcelsLocalActive
         ! get z from sigma:
         ! (see Section 3 of "The governing equations for CM1", 
         !  http://www2.mmm.ucar.edu/people/bryan/cm1/cm1_equations.pdf)
         pdata(np,prz) = pdata(np,przs) + pdata(np,prsig)*((zt-pdata(np,przs))*rzt)
       ENDDO
    endif

    if(timestats.ge.1) time_droplet=time_droplet+mytime()

    num_fallout_out = num_fallout

   end subroutine droplet_driver

!----------------------------------------------------------------------

   subroutine compute_droplet_substeps(dt,xf,yf,zf,sigmaf,pdata,pdata_locind,num_dropsub)

      use input, only : ib,ie,jb,je,kb,ke,ni,nj,nk,npvals,nparcelsLocal, &
          nparcelsLocalActive,nx,ny,axisymm,terrain_flag,viscosity,sc_num, &
          prx,pry,prz,prsig,prrp,prmult,ierr
      use constants
#ifdef MPI
      use mpi
#endif
      implicit none

      real, intent(in) :: dt
      real, intent(in), dimension(ib:ie+1) :: xf
      real, intent(in), dimension(jb:je+1) :: yf
      real, intent(in), dimension(ib:ie,jb:je,kb:ke+1) :: zf
      real, intent(in), dimension(kb:ke+1) :: sigmaf
      real, intent(inout), dimension(nparcelsLocal,npvals) :: pdata
      integer, intent(inout), dimension(nparcelsLocal,3) :: pdata_locind
      integer, intent(out) :: num_dropsub

      integer :: i,j,k,np,iflag,jflag,kflag
      real :: x3d,y3d,z3d,sig3d,dV,diffv,tauc_min
      real :: drop_radnc_local,drop_radnc_global
      real, dimension(ib:ie,jb:je,kb:ke) :: drop_radnc

      num_dropsub = 1

      if( dt.le.0.0 ) return

      !$acc data create(drop_radnc)

      !$acc parallel loop gang vector collapse(3) default(present) private(i,j,k)
      do k=1,nk
      do j=1,nj
      do i=1,ni
        drop_radnc(i,j,k) = 0.0
      enddo
      enddo
      enddo

      !$acc parallel loop gang vector default(present) &
      !$acc private(np,iflag,jflag,kflag,x3d,y3d,z3d,sig3d,dV)
      do np=1,nparcelsLocalActive
        x3d = pdata(np,prx)
        y3d = pdata(np,pry)
        if( .not. terrain_flag )then
          z3d = pdata(np,prz)
        else
          sig3d = pdata(np,prsig)
        endif

        iflag = undefined_index
        jflag = undefined_index
        kflag = undefined_index

        IF(nx.eq.1)THEN
          iflag = 1
        ELSE
          call find_horizontal_location_index (pdata_locind(np,1), x3d, ib, ie+1, xf, ni+1, iflag)
        ENDIF

        IF(axisymm.eq.1.or.ny.eq.1)THEN
          jflag = 1
        ELSE
          call find_horizontal_location_index (pdata_locind(np,2), y3d, jb, je+1, yf, nj+1, jflag)
        ENDIF

        if( iflag.ge.1 .and. iflag.le.ni .and. jflag.ge.1 .and. jflag.le.nj )then
          kflag = 1
          if( .not. terrain_flag )then
            if( z3d.ge.zf(iflag,jflag,kb) .and. z3d.le.zf(iflag,jflag,ke+1) )then
              do while( z3d.gt.zf(iflag,jflag,kflag+1) )
                kflag = kflag+1
              enddo
              pdata_locind(np,3) = kflag
            else
              kflag = undefined_index
            endif
          else
            if( sig3d.ge.sigmaf(kb) .and. sig3d.le.sigmaf(ke+1) )then
              call find_vertical_location_index (pdata_locind(np,3), sig3d, kb, ke+1, sigmaf, kflag, .TRUE.)
            else
              kflag = undefined_index
            endif
          endif

          if( kflag.ge.1 .and. kflag.le.nk )then
            dV = (xf(iflag+1)-xf(iflag))*(yf(jflag+1)-yf(jflag)) &
               *(zf(iflag,jflag,kflag+1)-zf(iflag,jflag,kflag))
            if( dV.gt.0.0 )then
              !$acc atomic update
              drop_radnc(iflag,jflag,kflag) = drop_radnc(iflag,jflag,kflag) &
                + pdata(np,prrp)*pdata(np,prmult)/dV
            endif
          endif
        endif
      enddo

      ! avg_rad*Nc = sum(mult*radius)/dV, so the largest value gives the
      ! shortest local cloud relaxation time.
      drop_radnc_local = 0.0
      !$acc parallel loop gang vector collapse(3) default(present) private(i,j,k) &
      !$acc reduction(max:drop_radnc_local)
      do k=1,nk
      do j=1,nj
      do i=1,ni
        drop_radnc_local = max(drop_radnc_local,drop_radnc(i,j,k))
      enddo
      enddo
      enddo

      !$acc end data

#ifdef MPI
      call MPI_ALLREDUCE(drop_radnc_local,drop_radnc_global,1,MPI_REAL, &
                         MPI_MAX,MPI_COMM_WORLD,ierr)
#else
      drop_radnc_global = drop_radnc_local
#endif

      diffv = viscosity/max(sc_num,1.0e-12)
      if( drop_radnc_global.gt.0.0 .and. diffv.gt.0.0 )then
        tauc_min = 1.0/(pi*diffv*drop_radnc_global)
        if( tauc_min.gt.0.0 .and. dt.gt.tauc_min )then
          num_dropsub = max(1,ceiling(dt/tauc_min))
        endif
      endif

   end subroutine compute_droplet_substeps

!----------------------------------------------------------------------

   subroutine droplet_coalescence_driver(dt,xf,yf,zf,sigmaf,pdata,pdata_locind)

      use input, only : ib,ie,jb,je,kb,ke,ni,nj,nk,npvals,nparcelsLocal, &
          nparcelsLocalActive,prrp,prmult,prms,prkap
      implicit none

      real, intent(in) :: dt
      real, intent(in), dimension(ib:ie+1) :: xf
      real, intent(in), dimension(jb:je+1) :: yf
      real, intent(in), dimension(ib:ie,jb:je,kb:ke+1) :: zf
      real, intent(in), dimension(kb:ke+1) :: sigmaf
      real, intent(inout), dimension(nparcelsLocal,npvals) :: pdata
      integer, intent(inout), dimension(nparcelsLocal,3) :: pdata_locind

      logical, parameter :: coal_enabled = .true.
      integer, parameter :: coal_nx = 1
      integer, parameter :: coal_ny = 1
      integer, parameter :: coal_nz = 1

      integer :: nactive,nci,ncj,nck,ncoal_cells
      integer :: np,c,iflag,jflag,kflag,ci,cj,ck,cell,slot
      integer :: first,last,p,j_idx,k_idx
      integer :: bad_cell_id,bad_pack_cursor,bad_pack_particles,packed_count
      integer :: bad_pair
      integer, dimension(:), allocatable :: cell_id,cell_count,cell_start
      integer, dimension(:), allocatable :: cell_cursor,cell_particles
      real :: xi_j,xi_k,remaining_j,gam_til,p_alpha
      real :: r_j,r_k,ms_j,ms_k,kap_j,kap_k
      real :: new_rad,new_ms,new_kap,new_mult_j,new_mult_k

      if( .not. coal_enabled ) return
      if( dt.le.0.0 ) return
      if( nparcelsLocalActive.le.1 ) return

      nactive = nparcelsLocalActive
      nci = max(1,(ni+coal_nx-1)/coal_nx)
      ncj = max(1,(nj+coal_ny-1)/coal_ny)
      nck = max(1,(nk+coal_nz-1)/coal_nz)
      ncoal_cells = nci*ncj*nck

      if( ncoal_cells.lt.1 )then
        stop 'DROPLET COALESCENCE BAD PROTOTYPE STATE'
      endif

      allocate(cell_id(nactive),cell_count(ncoal_cells), &
               cell_start(ncoal_cells+1),cell_cursor(ncoal_cells), &
               cell_particles(nactive))

      !$acc data create(cell_id,cell_count,cell_start,cell_cursor,cell_particles) &
      !$acc      present(pdata,pdata_locind)

      !$acc parallel loop gang vector default(present)
      do np=1,nactive
        cell_id(np) = 0
        cell_particles(np) = 0
      enddo
      !$acc end parallel

      !$acc parallel loop gang vector default(present)
      do c=1,ncoal_cells
        cell_count(c) = 0
        cell_cursor(c) = 0
      enddo
      !$acc end parallel

      bad_cell_id = 0
      !$acc parallel loop gang vector default(present) &
      !$acc private(iflag,jflag,kflag,ci,cj,ck,cell) reduction(+:bad_cell_id)
      do np=1,nactive
        iflag = pdata_locind(np,1)
        jflag = pdata_locind(np,2)
        kflag = pdata_locind(np,3)

        if( iflag.ge.1 .and. iflag.le.ni .and. &
            jflag.ge.1 .and. jflag.le.nj .and. &
            kflag.ge.1 .and. kflag.le.nk )then
          ci = (iflag-1)/coal_nx + 1
          cj = (jflag-1)/coal_ny + 1
          ck = (kflag-1)/coal_nz + 1
          cell = ci + nci*(cj-1) + nci*ncj*(ck-1)
          cell_id(np) = cell
          !$acc atomic update
          cell_count(cell) = cell_count(cell) + 1
        else
          bad_cell_id = bad_cell_id + 1
        endif
      enddo
      !$acc end parallel

      if( bad_cell_id.gt.0 )then
        stop 'DROPLET COALESCENCE BAD CELL ID'
      endif

      !$acc serial present(cell_count,cell_start,cell_cursor)
      packed_count = 1
      do c=1,ncoal_cells
        cell_start(c) = packed_count
        cell_cursor(c) = packed_count
        packed_count = packed_count + cell_count(c)
      enddo
      cell_start(ncoal_cells+1) = packed_count
      !$acc end serial

      !$acc parallel loop gang vector default(present) private(cell,slot)
      do np=1,nactive
        cell = cell_id(np)
        !$acc atomic capture
        slot = cell_cursor(cell)
        cell_cursor(cell) = cell_cursor(cell) + 1
        !$acc end atomic
        cell_particles(slot) = np
      enddo
      !$acc end parallel

      bad_pack_cursor = 0
      !$acc parallel loop gang vector default(present) reduction(+:bad_pack_cursor)
      do c=1,ncoal_cells
        if( cell_cursor(c).ne.cell_start(c+1) )then
          bad_pack_cursor = bad_pack_cursor + 1
        endif
      enddo
      !$acc end parallel

      bad_pack_particles = 0
      !$acc parallel loop gang vector default(present) reduction(+:bad_pack_particles)
      do np=1,nactive
        if( cell_particles(np).lt.1 .or. cell_particles(np).gt.nactive )then
          bad_pack_particles = bad_pack_particles + 1
        endif
      enddo
      !$acc end parallel

      if( bad_pack_cursor.gt.0 .or. bad_pack_particles.gt.0 )then
        stop 'DROPLET COALESCENCE BAD PACKED LIST'
      endif

      bad_pair = 0
      !$acc parallel loop gang default(present) &
      !$acc private(first,last,p,j_idx,k_idx,xi_j,xi_k,remaining_j,gam_til,p_alpha) &
      !$acc private(r_j,r_k,ms_j,ms_k,kap_j,kap_k,new_rad,new_ms,new_kap,new_mult_j,new_mult_k) &
      !$acc reduction(+:bad_pair)
      do c=1,ncoal_cells
        first = cell_start(c)
        last = cell_start(c+1)-1
        do p=first,last-1,2
          j_idx = cell_particles(p)
          k_idx = cell_particles(p+1)

          if( pdata(j_idx,prmult).lt.pdata(k_idx,prmult) )then
            j_idx = cell_particles(p+1)
            k_idx = cell_particles(p)
          endif

          xi_j = pdata(j_idx,prmult)
          xi_k = pdata(k_idx,prmult)
          r_j = pdata(j_idx,prrp)
          r_k = pdata(k_idx,prrp)
          ms_j = pdata(j_idx,prms)
          ms_k = pdata(k_idx,prms)
          kap_j = pdata(j_idx,prkap)
          kap_k = pdata(k_idx,prkap)

          if( xi_j.le.0.0 .or. xi_k.le.0.0 .or. r_j.le.0.0 .or. r_k.le.0.0 )then
            bad_pair = bad_pair + 1
          else
            ! Prototype: force every candidate pair to coalesce once until
            ! the physical collision kernel and probability are added.
            p_alpha = 1.0
            if( p_alpha.ge.1.0 )then
              gam_til = 1.0
              remaining_j = xi_j - gam_til*xi_k
              new_rad = (gam_til*r_j**3 + r_k**3)**(1.0/3.0)
              new_ms = gam_til*ms_j + ms_k
              if( new_ms.gt.0.0 )then
                new_kap = (gam_til*ms_j*kap_j + ms_k*kap_k)/new_ms
              else
                new_kap = 0.5*(kap_j + kap_k)
              endif

              if( remaining_j.gt.0.0 )then
                pdata(j_idx,prmult) = remaining_j
                pdata(k_idx,prrp) = new_rad
                pdata(k_idx,prms) = new_ms
                pdata(k_idx,prkap) = new_kap
              else
                new_mult_j = 0.5*xi_k
                new_mult_k = xi_k - new_mult_j
                pdata(j_idx,prmult) = new_mult_j
                pdata(k_idx,prmult) = new_mult_k
                pdata(j_idx,prrp) = new_rad
                pdata(k_idx,prrp) = new_rad
                pdata(j_idx,prms) = new_ms
                pdata(k_idx,prms) = new_ms
                pdata(j_idx,prkap) = new_kap
                pdata(k_idx,prkap) = new_kap
              endif
            endif
          endif
        enddo
      enddo
      !$acc end parallel

      if( bad_pair.gt.0 )then
        stop 'DROPLET COALESCENCE BAD PAIR STATE'
      endif

      !$acc end data

      deallocate(cell_id,cell_count,cell_start,cell_cursor,cell_particles)

   end subroutine droplet_coalescence_driver


   subroutine project_droplet_qc_effc(xf,yf,zf,sigmaf,rho,pdata,pdata_locind,q3d,qa,effc)

      use input, only : ib,ie,jb,je,kb,ke,ibr,ier,jbr,jer,kbr,ker, &
          numq,ni,nj,nk,npvals,nparcelsLocal, &
          nparcelsLocalActive,nx,ny,axisymm,terrain_flag,nqc, &
          prx,pry,prz,prsig,prrp,prmult
      use constants
      implicit none

      real, intent(in), dimension(ib:ie+1) :: xf
      real, intent(in), dimension(jb:je+1) :: yf
      real, intent(in), dimension(ib:ie,jb:je,kb:ke+1) :: zf
      real, intent(in), dimension(kb:ke+1) :: sigmaf
      real, intent(in), dimension(ib:ie,jb:je,kb:ke) :: rho
      real, intent(inout), dimension(nparcelsLocal,npvals) :: pdata
      integer, intent(inout), dimension(nparcelsLocal,3) :: pdata_locind
      real, intent(inout), dimension(ib:ie,jb:je,kb:ke,numq) :: q3d,qa
      real, intent(inout), dimension(ibr:ier,jbr:jer,kbr:ker) :: effc

      integer :: i,j,k,np,iflag,jflag,kflag
      real :: x3d,y3d,z3d,sig3d,dV,watermass
      real, dimension(ib:ie,jb:je,kb:ke) :: sum_r2,sum_r3

      if( nqc.lt.1 ) return

      !$acc data create(sum_r2,sum_r3)

      !$acc parallel loop gang vector collapse(3) default(present) private(i,j,k)
      do k=kbr,ker
      do j=jbr,jer
      do i=ibr,ier
        effc(i,j,k) = 10.0e-6
      enddo
      enddo
      enddo

      !$acc parallel loop gang vector collapse(3) default(present) private(i,j,k)
      do k=1,nk
      do j=1,nj
      do i=1,ni
        q3d(i,j,k,nqc) = 0.0
        sum_r2(i,j,k) = 0.0
        sum_r3(i,j,k) = 0.0
      enddo
      enddo
      enddo

      !$acc parallel loop gang vector default(present) &
      !$acc private(np,iflag,jflag,kflag,x3d,y3d,z3d,sig3d,dV,watermass)
      do np=1,nparcelsLocalActive
        x3d = pdata(np,prx)
        y3d = pdata(np,pry)
        if( .not. terrain_flag )then
          z3d = pdata(np,prz)
        else
          sig3d = pdata(np,prsig)
        endif

        iflag = undefined_index
        jflag = undefined_index
        kflag = undefined_index

        IF(nx.eq.1)THEN
          iflag = 1
        ELSE
          call find_horizontal_location_index (pdata_locind(np,1), x3d, ib, ie+1, xf, ni+1, iflag)
        ENDIF

        IF(axisymm.eq.1.or.ny.eq.1)THEN
          jflag = 1
        ELSE
          call find_horizontal_location_index (pdata_locind(np,2), y3d, jb, je+1, yf, nj+1, jflag)
        ENDIF

        if( iflag.ge.1 .and. iflag.le.ni .and. jflag.ge.1 .and. jflag.le.nj )then
          kflag = 1
          if( .not. terrain_flag )then
            if( z3d.ge.zf(iflag,jflag,kb) .and. z3d.le.zf(iflag,jflag,ke+1) )then
              do while( z3d.gt.zf(iflag,jflag,kflag+1) )
                kflag = kflag+1
              enddo
              pdata_locind(np,3) = kflag
            else
              kflag = undefined_index
            endif
          else
            if( sig3d.ge.sigmaf(kb) .and. sig3d.le.sigmaf(ke+1) )then
              call find_vertical_location_index (pdata_locind(np,3), sig3d, kb, ke+1, sigmaf, kflag, .TRUE.)
            else
              kflag = undefined_index
            endif
          endif

          if( kflag.ge.1 .and. kflag.le.nk )then
            dV = (xf(iflag+1)-xf(iflag))*(yf(jflag+1)-yf(jflag)) &
               *(zf(iflag,jflag,kflag+1)-zf(iflag,jflag,kflag))
            watermass = rhow*4.0/3.0*pi*pdata(np,prrp)**3
            !$acc atomic update
            q3d(iflag,jflag,kflag,nqc) = q3d(iflag,jflag,kflag,nqc) &
              + watermass*pdata(np,prmult)/(rho(iflag,jflag,kflag)*dV)
            !$acc atomic update
            sum_r2(iflag,jflag,kflag) = sum_r2(iflag,jflag,kflag) &
              + pdata(np,prmult)*pdata(np,prrp)**2
            !$acc atomic update
            sum_r3(iflag,jflag,kflag) = sum_r3(iflag,jflag,kflag) &
              + pdata(np,prmult)*pdata(np,prrp)**3
          endif
        endif
      enddo

      !$acc parallel loop gang vector collapse(3) default(present) private(i,j,k)
      do k=1,nk
      do j=1,nj
      do i=1,ni
        qa(i,j,k,nqc) = q3d(i,j,k,nqc)
        if( sum_r2(i,j,k).gt.0.0 )then
          effc(i,j,k) = max(2.5e-6,min(sum_r3(i,j,k)/sum_r2(i,j,k),50.0e-6))
        endif
      enddo
      enddo
      enddo

      !$acc end data

   end subroutine project_droplet_qc_effc

!----------------------------------------------------------------------

   subroutine droplet_injection_driver(dt,mtime,xh,xf,yh,yf,zh,zf,zs,znt, &
                                       sigma,sigmaf,rho,ua,va,wa,ta,qa,prs, &
                                       s10,pdata,pdata_locind,num_fallout)

      use input, only : ib,ie,jb,je,kb,ke,ibl,iel,jbl,jel,numq,ni,nj, &
          nk,npvals,axisymm,terrain_flag,nx,ny,nparcelsLocal, &
          nparcelsLocalActive,prx,pry,prz,prsig,pru,prv,prw, &
          prusgs,prvsgs,prwsgs, &
          prt,prqv,prprs,prrho,prrp,prtp,drop_inject_elapse,drop_inject_time, &
          testcase,myid,timestats,time_droplet_inject,mytime,ierr
      use constants
#ifdef MPI
      use mpi
#endif
      implicit none

      real, intent(in) :: dt
      double precision, intent(in) :: mtime
      real, intent(in), dimension(ib:ie) :: xh
      real, intent(in), dimension(ib:ie+1) :: xf
      real, intent(in), dimension(jb:je) :: yh
      real, intent(in), dimension(jb:je+1) :: yf
      real, intent(in), dimension(ib:ie,jb:je,kb:ke) :: zh
      real, intent(in), dimension(ib:ie,jb:je,kb:ke+1) :: zf
      real, intent(in), dimension(ib:ie,jb:je) :: zs,znt
      real, intent(in), dimension(kb:ke) :: sigma
      real, intent(in), dimension(kb:ke+1) :: sigmaf
      real, intent(inout), dimension(ib:ie,jb:je,kb:ke) :: rho,ta,prs
      real, intent(inout), dimension(ib:ie+1,jb:je,kb:ke) :: ua
      real, intent(inout), dimension(ib:ie,jb:je+1,kb:ke) :: va
      real, intent(inout), dimension(ib:ie,jb:je,kb:ke+1) :: wa
      real, intent(inout), dimension(ib:ie,jb:je,kb:ke,numq) :: qa
      real, intent(in), dimension(ibl:iel,jbl:jel) :: s10
      real, intent(inout), dimension(nparcelsLocal,npvals) :: pdata
      integer, intent(inout), dimension(nparcelsLocal,3) :: pdata_locind
      integer, intent(in) :: num_fallout

      integer :: i,j,np,iflag,jflag,kflag
      integer :: doinject,my_reintro
      real :: x3d,y3d,z3d,sig3d
      integer(i8) :: np_tmp,total_fallout
      real :: uval,vval,wval,qval,prsval,tval,rhoval,sigdot
      real :: radmin,radmax,Tpmin,Tpmax
      real :: qfmin,qfmax,Tfmin,Tfmax
      real :: prsmin,prsmax,rhomin,rhomax
      real :: usgsmin,usgsmax,vsgsmin,vsgsmax,wsgsmin,wsgsmax
      real :: minvals(9),maxvals(9)

      !----------------------------------------------------------------------
      ! Final thing: Inject droplets which will be active on the next call of droplet_driver
      ! Requires inputting the current 10-meter wind speed
      u10_ssgf = 0.0
      !$acc update host(s10)
      do j=1,nj
        do i=1,ni
          u10_ssgf = u10_ssgf + s10(i,j)
        enddo
      enddo

#ifdef MPI
      call mpi_allreduce(mpi_in_place,u10_ssgf,1,mpi_double_precision,mpi_sum,mpi_comm_world,ierr)
#endif
      u10_ssgf = u10_ssgf/dble(nx*ny)


      doinject = 0
      total_fallout = 0_i8

      !Only inject if a certain time has elapsed (specified in the namelist file)
      !Negative drop_inject_elapse means inject every time step
      if (drop_inject_elapse .lt. 0.0) then
         doinject = 1
      elseif (floor(mtime/drop_inject_elapse) .ne. floor((mtime+dt)/drop_inject_elapse)) then
         doinject = 1
      end if

      !Only inject if past a certain time (specified in the namelist file)
      if (mtime .lt. drop_inject_time) then
         doinject=0
      end if

      if (testcase.eq.17) then
         total_fallout = int(num_fallout,i8)
#ifdef MPI
         call mpi_allreduce(mpi_in_place,total_fallout,1,mpi_integer8,mpi_sum,mpi_comm_world,ierr)
#endif
      end if

      if (testcase.eq.17 .and. total_fallout.gt.0_i8) then
         doinject = 1
      end if

      if (doinject .eq. 1) then

        my_reintro = 0

        if (testcase.eq.15) then  !Hurricane boundary layer spray LES case
          call droplet_injection(pdata,xf,yf,max(drop_inject_elapse,dt),mtime,my_reintro)
        end if

        if (testcase.eq.16) then  !Pi chamber
          call droplet_injection_pi(pdata,xf,yf,max(drop_inject_elapse,dt),mtime,my_reintro)
        end if

        if (testcase.eq.17) then
          call droplet_fallout_reinjection(pdata,xf,yf,num_fallout,mtime,my_reintro)
        end if
        !$acc wait

        !This loop isn't strictly necessary, but populate the interpolated values to the newly injected particles
        !Doesn't affect solution at all! Since interpolation happens at start of droplet_driver
        !But makes sure that the interpolated mean quantities in droplet_diag are meaningful
        !$acc parallel loop gang vector default(present)
        do np=nparcelsLocalActive-my_reintro+1,nparcelsLocalActive
          pdata_locind(np,1) = undefined_index
          pdata_locind(np,2) = undefined_index
          pdata_locind(np,3) = undefined_index
          x3d = pdata(np,prx)
          y3d = pdata(np,pry)
          if( .not. terrain_flag )then
            z3d = pdata(np,prz)
          else
            sig3d = pdata(np,prsig)
          endif
          iflag = undefined_index
          jflag = undefined_index
          kflag = 0
          IF(nx.eq.1)THEN
            iflag = 1
          ELSE
            ! cm1r19:
            call find_horizontal_location_index (pdata_locind(np,1), x3d, ib, ie+1, xf, ni+1, iflag)
          ENDIF
          IF(axisymm.eq.1.or.ny.eq.1)THEN
            jflag = 1
          ELSE
            ! cm1r19:
            call find_horizontal_location_index (pdata_locind(np,2), y3d, jb, je+1, yf, nj+1, jflag)
          ENDIF
          kflag = 1
          if( .not. terrain_flag )then
            do while( z3d.gt.zf(iflag,jflag,kflag+1) )
              kflag = kflag+1
            enddo
            pdata_locind(np,3) = kflag
          else
            call find_vertical_location_index (pdata_locind(np,3), sig3d, kb, ke+1, sigmaf, kflag, .TRUE.)
          endif
          call interpolate_to_parcel(np,iflag,jflag,kflag,x3d,y3d,z3d,sig3d, &
                                     uval,vval,wval,tval,qval,rhoval,prsval, &
                                     xh,xf,yh,yf,zh,zf,zs,znt,sigma,sigmaf, &
                                     ua,va,wa,ta,qa,rho,prs,sigdot)
          !Now set to actual interpolated values
          pdata(np,pru) = uval
          pdata(np,prv) = vval
          pdata(np,prw) = wval
          pdata(np,prt) = tval
          pdata(np,prqv) = qval
          pdata(np,prprs) = prsval
          pdata(np,prrho) = rhoval
        enddo
        !$acc wait
      end if    !doinject

      np_tmp = int(nparcelsLocalActive,i8)
      radmin = huge(1.0)
      radmax = -huge(1.0)
      Tpmin = huge(1.0)
      Tpmax = -huge(1.0)
      qfmin = huge(1.0)
      qfmax = -huge(1.0)
      Tfmin = huge(1.0)
      Tfmax = -huge(1.0)
      prsmin = huge(1.0)
      prsmax = -huge(1.0)
      rhomin = huge(1.0)
      rhomax = -huge(1.0)
      usgsmin = huge(1.0)
      usgsmax = -huge(1.0)
      vsgsmin = huge(1.0)
      vsgsmax = -huge(1.0)
      wsgsmin = huge(1.0)
      wsgsmax = -huge(1.0)

      !$acc parallel loop gang vector default(present) &
      !$acc          reduction(min:radmin,Tpmin,qfmin,Tfmin,prsmin,rhomin,usgsmin,vsgsmin,wsgsmin) &
      !$acc          reduction(max:radmax,Tpmax,qfmax,Tfmax,prsmax,rhomax,usgsmax,vsgsmax,wsgsmax)
      do np=1,nparcelsLocalActive
         radmin = min(radmin,pdata(np,prrp))
         radmax = max(radmax,pdata(np,prrp))
         Tpmin = min(Tpmin,pdata(np,prtp))
         Tpmax = max(Tpmax,pdata(np,prtp))
         qfmin = min(qfmin,pdata(np,prqv))
         qfmax = max(qfmax,pdata(np,prqv))
         Tfmin = min(Tfmin,pdata(np,prt))
         Tfmax = max(Tfmax,pdata(np,prt))
         prsmin = min(prsmin,pdata(np,prprs))
         prsmax = max(prsmax,pdata(np,prprs))
         rhomin = min(rhomin,pdata(np,prrho))
         rhomax = max(rhomax,pdata(np,prrho))
         usgsmin = min(usgsmin,pdata(np,prusgs))
         usgsmax = max(usgsmax,pdata(np,prusgs))
         vsgsmin = min(vsgsmin,pdata(np,prvsgs))
         vsgsmax = max(vsgsmax,pdata(np,prvsgs))
         wsgsmin = min(wsgsmin,pdata(np,prwsgs))
         wsgsmax = max(wsgsmax,pdata(np,prwsgs))
      end do
      !$acc end parallel
      !$acc wait

#ifdef MPI
      call mpi_allreduce(mpi_in_place,np_tmp,1,mpi_integer8,mpi_sum,mpi_comm_world,ierr)
      minvals = (/ radmin,Tpmin,qfmin,Tfmin,prsmin,rhomin,usgsmin,vsgsmin,wsgsmin /)
      maxvals = (/ radmax,Tpmax,qfmax,Tfmax,prsmax,rhomax,usgsmax,vsgsmax,wsgsmax /)
      call mpi_allreduce(mpi_in_place,minvals,9,mpi_real,mpi_min,mpi_comm_world,ierr)
      call mpi_allreduce(mpi_in_place,maxvals,9,mpi_real,mpi_max,mpi_comm_world,ierr)
      radmin = minvals(1)
      Tpmin = minvals(2)
      qfmin = minvals(3)
      Tfmin = minvals(4)
      prsmin = minvals(5)
      rhomin = minvals(6)
      usgsmin = minvals(7)
      vsgsmin = minvals(8)
      wsgsmin = minvals(9)
      radmax = maxvals(1)
      Tpmax = maxvals(2)
      qfmax = maxvals(3)
      Tfmax = maxvals(4)
      prsmax = maxvals(5)
      rhomax = maxvals(6)
      usgsmax = maxvals(7)
      vsgsmax = maxvals(8)
      wsgsmax = maxvals(9)
#endif
      if (np_tmp.le.0_i8) then
         radmin = 0.0
         radmax = 0.0
         Tpmin = 0.0
         Tpmax = 0.0
         qfmin = 0.0
         qfmax = 0.0
         Tfmin = 0.0
         Tfmax = 0.0
         prsmin = 0.0
         prsmax = 0.0
         rhomin = 0.0
         rhomax = 0.0
         usgsmin = 0.0
         usgsmax = 0.0
         vsgsmin = 0.0
         vsgsmax = 0.0
         wsgsmin = 0.0
         wsgsmax = 0.0
      end if

      if (myid==0) then
         !write(*,'(a8,3i)')  'DHR1:',myid,np_tmp,nparcelsLocalActive
         write(*,'(a18,i18,18(a,1pe15.6))') 'Total particles:',np_tmp, &
                                            ' rmin=',radmin,' rmax=',radmax, &
                                            ' Tpmin=',Tpmin,' Tpmax=',Tpmax, &
                                            ' qfmin=',qfmin,' qfmax=',qfmax, &
                                            ' Tfmin=',Tfmin,' Tfmax=',Tfmax, &
                                            ' prsmin=',prsmin,' prsmax=',prsmax, &
                                            ' rhomin=',rhomin,' rhomax=',rhomax, &
                                            ' usgsmin=',usgsmin,' usgsmax=',usgsmax, &
                                            ' vsgsmin=',vsgsmin,' vsgsmax=',vsgsmax, &
                                            ' wsgsmin=',wsgsmin,' wsgsmax=',wsgsmax
      end if

      if(timestats.ge.1) time_droplet_inject=time_droplet_inject+mytime()

   end subroutine droplet_injection_driver

!----------------------------------------------------------------------

   subroutine BE_integration(dt,dbldt,nstep,mtime,np,seed_base,pdata,pdata_locind,xf,yf,zf, &
                             iflag,jflag, &
                             x3d,y3d,z3d,sig3d,uval,vval,wval,qval, &
                             khhval,khvval,dkhvdzval, &
                             sigsgsval,dsgsdxval,dsgsdyval,dsgsdzval, &
                             epssgsval,lsgsval,fsval, &
                             rhoval,prsval,tval,Nup,rhop0,taup0,rp0, &
                             part_grav1,part_grav2,part_grav3,debug, &
                             dlogsig_abs,dlogsig_valid,neighbor,num_fallout,errcode)

      !$acc routine seq

      use input, only : ib,ie,jb,je,kb,ke,numq,npvals,nx,ny,viscosity, &
          pr_num,sc_num,axisymm,terrain_flag,maxz,minx,maxx,miny,maxy, &
          prvpx,prvpy,prvpz,prusgs,prvsgs,prwsgs,prsigsgs, &
          prrp,prrp0,prms,prkap,prtp,prx,pry,prsig, &
          prz,pru,prv, &
          prw,prt,prqv,prprs,prrho,pract,prtime,prmult,ni,nj,mywest, &
          mysw,mynw,myeast,myse,myne,mysouth,mynorth,nparcelsLocal, &
          myid,dx,dy,pi_sp,pi_dp,ngxy,nbc,sbc,ebc,wbc,tsk0,drop_evap,drop_sgs_opt
      use constants , only : rhow,rhow_dp,undefined_index,cpl,cpl_dp,cp_dp,i8
      use comm_module
      use parcel_module
      use mpi

      implicit none

      double precision, intent(in) :: dbldt,mtime
      real, intent(in), dimension(ib:ie+1) :: xf
      real, intent(in), dimension(jb:je+1) :: yf
      real, intent(in), dimension(ib:ie,jb:je,kb:ke+1) :: zf
      integer, intent(in) :: nstep,np,iflag,jflag
      integer(i8), intent(in) :: seed_base
      logical, intent(in) :: debug
      real, intent(inout) :: x3d,y3d,z3d,sig3d
      real, intent(out) :: dlogsig_abs
      real, intent(in) :: uval,vval,wval,qval,rhoval,prsval,tval
      real, intent(in) :: khhval,khvval,dkhvdzval
      real, intent(in) :: sigsgsval,dsgsdxval,dsgsdyval,dsgsdzval
      real, intent(in) :: epssgsval,lsgsval,fsval
      real, intent(inout), dimension(nparcelsLocal,npvals) :: pdata
      integer, intent(inout), dimension(nparcelsLocal,3) :: pdata_locind
      real, intent(out) :: Nup
      real, intent(inout) :: rhop0,taup0,rp0
      real, intent(in) :: dt,part_grav1,part_grav2,part_grav3
      integer, intent(out) :: neighbor  ! indicate which MPI region a droplet 
                                        ! stays after this time step 
      integer, intent(out) :: dlogsig_valid
      integer, intent(inout) :: num_fallout
      integer, intent(inout) :: errcode

      real :: dt2
      real :: xrhs1,xrhs2,xrhs3,vrhs1,vrhs2,vrhs3
      real :: vtmp1,vtmp2,vtmp3
      real :: k1xp1,k1xp2,k1xp3,k1vp1,k1vp2,k1vp3
      real :: tprhs,tptmp
      real :: k1tp,k2tp,k1rp,k2rp
      real :: rprhs,rptmp
      real :: Rep,Shp,diffnorm
      real :: tp0
      real :: sig1
      real :: top,bot,restime10_tmp,rad10_tmp
      real :: north,south,east,west
      real :: dzbot,dztop,zbuf_bot,zbuf_top
      integer :: i,j,k,ibin,ibin_res
      double precision :: taup,volp,rhop,tmp_coeff
      double precision :: taup_scale,dt_nondim
      double precision :: guess
      double precision :: rt_zeros(2),rt_start(2)
      logical :: is_local
      integer :: mflag,flag

      dlogsig_abs = 0.0
      dlogsig_valid = 0

      !Store interpolated quantities for the sake of statistics
      pdata(np,pru) = uval
      pdata(np,prv) = vval
      pdata(np,prw) = wval
  
      pdata(np,prt) = tval
      pdata(np,prqv) = qval
      pdata(np,prprs) = prsval
      pdata(np,prrho) = rhoval


!-----------------------------------------------------
!  Update droplet position, velocity, etc.
!-----------------------------------------------------

      xrhs1 = pdata(np,prvpx)
      xrhs2 = pdata(np,prvpy)
      xrhs3 = pdata(np,prvpz)
      volp  = (4.0d0/3.0d0)*pi_dp*dble(pdata(np,prrp))**3
      rhop  = (dble(pdata(np,prms))+volp*rhow_dp)/volp  !Density including the solute mass
      taup  = rhop*(2.0d0*dble(pdata(np,prrp)))**2/(18.0d0*dble(rhoval)*dble(viscosity))

      !Original, for calculating changes in momentum, mass, and energy
      rhop0 = rhop
      taup0 = taup
      rp0   = pdata(np,prrp)
      tp0   = pdata(np,prtp)
!!!      volp0 = 4.0/3.0*pi_sp*rp0**3    ! not used


      diffnorm = sqrt( (uval-pdata(np,prvpx))**2+ &
                       (vval-pdata(np,prvpy))**2+ &
                       (wval-pdata(np,prvpz))**2)

      Rep = 2.0*pdata(np,prrp)*diffnorm/viscosity
      Nup = 2.0 + 0.6*sqrt(Rep)*pr_num**(1.0/3.0)
      Shp = 2.0 + 0.6*sqrt(Rep)*sc_num**(1.0/3.0)

      vrhs1 = (1.0d0/taup)*(uval - pdata(np,prvpx)) + part_grav1
      vrhs2 = (1.0d0/taup)*(vval - pdata(np,prvpy)) + part_grav2
      vrhs3 = (1.0d0/taup)*(wval - pdata(np,prvpz)) + part_grav3

      !Position and velocity are straightforward:

      x3d = pdata(np,prx) + dt*pdata(np,prvpx)
      y3d = pdata(np,pry) + dt*pdata(np,prvpy)
      z3d = pdata(np,prz) + dt*pdata(np,prvpz)

      if (drop_sgs_opt.eq.1) then
        call sfs_position_update(dt,nstep,mtime,np,seed_base,pdata, &
                                 x3d,y3d,z3d,khhval,khvval,dkhvdzval)
      endif
      if (drop_sgs_opt.eq.2) then
        call sfs_velocity_update(dt,nstep,mtime,np,seed_base,pdata, &
                                 x3d,y3d,z3d,sigsgsval, &
                                 dsgsdxval,dsgsdyval,dsgsdzval, &
                                 epssgsval,lsgsval,fsval,dlogsig_abs,dlogsig_valid)
      endif

      if (x3d.ne.x3d .or. y3d.ne.y3d .or. z3d.ne.z3d) then
        errcode = max(errcode,54321)
      endif

      pdata(np,prvpx) = (pdata(np,prvpx) + uval*(dbldt/taup) + dbldt*part_grav1)/(1.0d0 + dbldt/taup)
      pdata(np,prvpy) = (pdata(np,prvpy) + vval*(dbldt/taup) + dbldt*part_grav2)/(1.0d0 + dbldt/taup)
      pdata(np,prvpz) = (pdata(np,prvpz) + wval*(dbldt/taup) + dbldt*part_grav3)/(1.0d0 + dbldt/taup)

      if (pdata(np,prvpx).ne.pdata(np,prvpx) .or. &
          pdata(np,prvpy).ne.pdata(np,prvpy) .or. &
          pdata(np,prvpz).ne.pdata(np,prvpz)) then
        errcode = max(errcode,54322)
      endif

      !Nonlinear solver for the radius and temperature:
      !Only do this if the droplet evaporation is turned on
      if (drop_evap.eq.1) then

      !Nondimensionalize parameters before the solver using 1-micron water droplet as ref
      taup_scale = rhow_dp*(1.0d-6)**2/(18.0d0*dble(rhoval)*dble(viscosity))

      dt_nondim = dbldt/taup_scale
      
      guess = 0.0d0

      !Gives initial guess into nonlinear solver
      !mflag = 0, has equilibrium radius; mflag = 1, no equilibrium (uses itself as initial guess)
      call rad_solver2(guess,mflag,prsval,rhoval,tval,qval, &
                       pdata(np,prtp),pdata(np,prms),pdata(np,prkap), &
                       pdata(np,prrp),np)

      !Nondimensionalize the guesses
      if (mflag.eq.0) then
         rt_start(1) = guess/dble(pdata(np,prrp))
         rt_start(2) = dble(tval)/dble(pdata(np,prtp))
      else
         rt_start(1) = 1.0
         rt_start(2) = 1.0
      end if

      !Start using the standard Gauss-Newton algorithm
      call gauss_newton_2d(dble(diffnorm),dt_nondim,taup_scale, &
                           rt_start,rt_zeros,flag,dble(prsval), &
                           dble(rhoval),dble(tval),dble(qval), &
                           dble(pdata(np,prtp)),dble(pdata(np,prms)), &
                           dble(pdata(np,prkap)),dble(pdata(np,prrp)),np)

      !If Gauss-Newton failed to converge, flag is set to 1 and try Levenberg-Marquardt algorithm
      if (flag==1) then
         num100 = num100+1.0
         call LV_solver(dble(diffnorm),dt_nondim,taup_scale,rt_start, &
                        rt_zeros,flag,dble(prsval),dble(rhoval), &
                        dble(tval),dble(qval),dble(pdata(np,prtp)), &
                        dble(pdata(np,prms)),dble(pdata(np,prkap)), &
                        dble(pdata(np,prrp)),np)
      end if

      !In rare cases both nonlinear solvers fail to converge
      if (flag==1)  then

       num1000 = num1000+1.0

       !If this happens keep radius unchanged and temp equal to surrounding
       rt_zeros(1) = 1.0
       rt_zeros(2) = tval/pdata(np,prtp)

      end if

      !Now redimsionalize
      pdata(np,prrp) = rt_zeros(1)*pdata(np,prrp)
      pdata(np,prtp) = rt_zeros(2)*pdata(np,prtp)

      else !If droplet evaporation is turned off, leave radius unchanged and update temperature via BE

      tmp_coeff = Nup/3.0/pr_num*(rhop/rhow_dp)*(cp_dp/cpl_dp)/taup
      pdata(np,prtp) = (pdata(np,prtp) + tmp_coeff*dbldt*tval)/(1+dbldt*tmp_coeff)


      end if !drop_evap

      !Update the droplet timer
      pdata(np,prtime) = pdata(np,prtime) + dt

      !Finally, take care of particle BCs

      !Wall BCs:
      dzbot = max(zf(iflag,jflag,kb+1)-zf(iflag,jflag,kb),1.0e-6)
      dztop = max(zf(iflag,jflag,ke+1)-zf(iflag,jflag,ke),1.0e-6)
      ! Radius can be smaller than single-precision spacing; keep particles off exact wall/full levels.
      zbuf_bot = max(pdata(np,prrp),1.0e-6*dzbot)
      zbuf_top = max(pdata(np,prrp),1.0e-6*dztop)
      top = maxz-zbuf_top
      bot = zbuf_bot
      east = maxx-pdata(np,prrp)
      west = minx+pdata(np,prrp)
      north = maxy-pdata(np,prrp)
      south = miny+pdata(np,prrp)


      !Temporary no-flux vertical boundary option:
      !if (z3d.gt.top) then
      !  z3d = top - (z3d-top)
      !  pdata_locind(np,3) = undefined_index
      !endif
      !if (z3d.lt.bot) then
      !  z3d = bot + (bot-z3d)
      !  pdata_locind(np,3) = undefined_index
      !endif
      !z3d = min(max(z3d,bot),top)

      !The different cases that kill a particle:
      if (z3d.gt.top .or. z3d.lt.bot) then
         !Temporary: don't advance position to avoid MPI rank confusion
         x3d = pdata(np,prx)
         y3d = pdata(np,pry)
         z3d = pdata(np,prz)
         pdata(np,pract) = -1.0  !Signal this as no longer alive
      end if

      if (x3d.gt.east .and. ebc.eq.4) then
         !Temporary: don't advance position to avoid MPI rank confusion
         x3d = pdata(np,prx)
         y3d = pdata(np,pry)
         pdata(np,pract) = -1.0  !Signal this as no longer alive
      end if

      if (x3d.lt.west .and. wbc.eq.4) then
         !Temporary: don't advance position to avoid MPI rank confusion
         x3d = pdata(np,prx)
         y3d = pdata(np,pry)
         pdata(np,pract) = -1.0  !Signal this as no longer alive
      end if

      if (y3d.gt.north .and. nbc.eq.4) then
         !Temporary: don't advance position to avoid MPI rank confusion
         x3d = pdata(np,prx)
         y3d = pdata(np,pry)
         pdata(np,pract) = -1.0  !Signal this as no longer alive
      end if

      if (y3d.lt.south .and. sbc.eq.4) then
         !Temporary: don't advance position to avoid MPI rank confusion
         x3d = pdata(np,prx)
         y3d = pdata(np,pry)
         pdata(np,pract) = -1.0  !Signal this as no longer alive
      end if


      !Collect statistics on all of those that have died
      if (pdata(np,pract).lt.0.0) then

            num_fallout = num_fallout + 1

            !Collect some statistics on those falling out:

            num_destroyed = num_destroyed + pdata(np,prmult)

            mass_destroyed = mass_destroyed + (pdata(np,prms)+rhow*4.0/3.0*pi_sp*pdata(np,prrp)**3)*pdata(np,prmult)

            eng_destroyed = eng_destroyed + (pdata(np,prms)+rhow*4.0/3.0*pi_sp*pdata(np,prrp)**3)*pdata(np,prmult)*cpl*pdata(np,prtp)

            m1_destroyed = m1_destroyed + (pdata(np,prms)+rhow*4.0/3.0*pi_sp*pdata(np,prrp)**3)*pdata(np,prmult)*pdata(np,prvpx)
 
            m2_destroyed = m2_destroyed + (pdata(np,prms)+rhow*4.0/3.0*pi_sp*pdata(np,prrp)**3)*pdata(np,prmult)*pdata(np,prvpy)
 
            !Reentry is initial minus final
            mass_reentry = mass_reentry + ( (pdata(np,prms)+rhow*4.0/3.0*pi_sp*pdata(np,prrp0)**3)*pdata(np,prmult) - (pdata(np,prms)+rhow*4.0/3.0*pi_sp*pdata(np,prrp)**3)*pdata(np,prmult) )

            eng_reentry = eng_reentry + ( (pdata(np,prms)+rhow*4.0/3.0*pi_sp*pdata(np,prrp0)**3)*pdata(np,prmult)*cpl*tsk0 -(pdata(np,prms)+rhow*4.0/3.0*pi_sp*pdata(np,prrp)**3)*pdata(np,prmult)*cpl*pdata(np,prtp) ) 

            m1_reentry = m1_reentry + ( 0 - (pdata(np,prms)+rhow*4.0/3.0*pi_sp*pdata(np,prrp)**3)*pdata(np,prmult)*pdata(np,prvpx) )
 
            m2_reentry = m2_reentry + ( 0 - (pdata(np,prms)+rhow*4.0/3.0*pi_sp*pdata(np,prrp)**3)*pdata(np,prmult)*pdata(np,prvpy) )
 
            !Log this dead particle into the relevant histograms
            !First residence time
            restime10_tmp = log10(pdata(np,prtime))

            if (restime10_tmp .gt. restime_max10 + 0.5*dhres) then
               ibin_res = nbins
            elseif (restime10_tmp .lt. restime_min10 - 0.5*dhres) then
               ibin_res = 1
            else
               ibin_res = (floor((restime10_tmp-(restime_min10-0.5*dhres))/dhres)+1)+1
            end if

            !The the droplet size at fallout
            rad10_tmp = log10(pdata(np,prrp))
        
            if (rad10_tmp .gt. rmax10 + 0.5*dhrad) then
               ibin = nbins
            elseif (rad10_tmp .lt. rmin10 - 0.5*dhrad) then
               ibin = 1
            else
               ibin = (floor((rad10_tmp-(rmin10-0.5*dhrad))/dhrad)+1)+1
            end if

            !$acc atomic update
            hist_restime(ibin_res,ibin) = hist_restime(ibin_res,ibin) + pdata(np,prmult)

            !$acc atomic update
            hist_fallrad(ibin) = hist_fallrad(ibin) + pdata(np,prmult)


            !If it was killed, set parameters to undefined so it gets removed from list later
            neighbor = undefined_index
            pdata_locind(np,1) = undefined_index
            pdata_locind(np,2) = undefined_index
            pdata_locind(np,3) = undefined_index
      else

         !If it was not killed, look for neighbors and prepare for transfer

#ifdef MPI
         ! determine which new MPI region this droplet 
         ! enters or stays for the next time step
 
         call check_droplet_ownership(x3d,y3d,xf,yf,is_local, &
                                   neighbor,errcode)
         !Returns neighbor = undefined_index when it stays put
         !Otherwise neighbor = some integer when is moving

         !Found a meaningful neighbor: should NOT happen when particle is dying
         if ( neighbor .ne. undefined_index ) then
            pdata_locind(np,1) = undefined_index
            pdata_locind(np,2) = undefined_index
            pdata_locind(np,3) = undefined_index
         end if
#endif

         !Periodic boundaries in x and y
         !Should only get here if ebc,wbc,nbc,sbc .ne. 4 
         !since these would have been marked dead above if they exceeded maxx,minx,maxy,miny
         if ( x3d .lt. minx) then
            x3d = x3d + ( maxx - minx )
            pdata_locind(np,1) = undefined_index
         end if
         if ( x3d .gt. maxx) then
            x3d = x3d - ( maxx - minx )
            pdata_locind(np,1) = undefined_index
         end if

         if ( y3d .gt. maxy .and. axisymm .ne. 1 .and. ny .ne. 1) then
            y3d = y3d - ( maxy - miny )
            pdata_locind(np,2) = undefined_index
         end if
         if ( y3d .lt. miny .and. axisymm .ne. 1 .and. ny .ne. 1) then
            y3d = y3d + ( maxy - miny )
            pdata_locind(np,2) = undefined_index
         end if
   
         pdata(np,prx) = x3d
         pdata(np,pry) = y3d
         if ( .not. terrain_flag )then
            pdata(np,prz) = z3d
         else
            pdata(np,prsig) = sig3d
         end if

      end if


      if ( pdata_locind(np,1) .eq. undefined_index .or. &
           pdata_locind(np,2) .eq. undefined_index ) then
           pdata_locind(np,3) = undefined_index
      end if

      end subroutine BE_integration

      subroutine compute_sfs_fs_profile(ua,va,wa,tkea,fs_sgs)

      use input, only : ib,ie,jb,je,kb,ke,ibt,iet,jbt,jet,kbt,ket, &
                        ni,nj,nk,nx,ny,ierr
#ifdef MPI
      use mpi
#endif
      implicit none

      real, intent(in), dimension(ib:ie+1,jb:je,kb:ke) :: ua
      real, intent(in), dimension(ib:ie,jb:je+1,kb:ke) :: va
      real, intent(in), dimension(ib:ie,jb:je,kb:ke+1) :: wa
      real, intent(in), dimension(ibt:iet,jbt:jet,kbt:ket) :: tkea
      real, intent(out), dimension(kb:ke+1) :: fs_sgs

      integer :: i,j,k
      double precision :: denom,er_w,ngrid
      double precision, dimension(1:nk) :: uavg,vavg,uvar,vvar
      double precision, dimension(1:nk+1) :: wavg,wvar,esavg

      ngrid = dble(nx*ny)

      do k=1,nk
         uavg(k) = 0.0d0
         vavg(k) = 0.0d0
         uvar(k) = 0.0d0
         vvar(k) = 0.0d0
      enddo
      do k=1,nk+1
         wavg(k) = 0.0d0
         wvar(k) = 0.0d0
         esavg(k) = 0.0d0
         fs_sgs(k) = 0.0
      enddo

      do k=1,nk
         do j=1,nj
            do i=1,ni
               uavg(k) = uavg(k) + dble(ua(i,j,k))
               vavg(k) = vavg(k) + dble(va(i,j,k))
            enddo
         enddo
      enddo
      do k=1,nk+1
         do j=1,nj
            do i=1,ni
               wavg(k) = wavg(k) + dble(wa(i,j,k))
               esavg(k) = esavg(k) + dble(max(tkea(i,j,k),0.0))
            enddo
         enddo
      enddo

#ifdef MPI
      call mpi_allreduce(mpi_in_place,uavg,nk,mpi_double_precision,mpi_sum,mpi_comm_world,ierr)
      call mpi_allreduce(mpi_in_place,vavg,nk,mpi_double_precision,mpi_sum,mpi_comm_world,ierr)
      call mpi_allreduce(mpi_in_place,wavg,nk+1,mpi_double_precision,mpi_sum,mpi_comm_world,ierr)
      call mpi_allreduce(mpi_in_place,esavg,nk+1,mpi_double_precision,mpi_sum,mpi_comm_world,ierr)
#endif

      do k=1,nk
         uavg(k) = uavg(k)/ngrid
         vavg(k) = vavg(k)/ngrid
      enddo
      do k=1,nk+1
         wavg(k) = wavg(k)/ngrid
         esavg(k) = esavg(k)/ngrid
      enddo

      do k=1,nk
         do j=1,nj
            do i=1,ni
               uvar(k) = uvar(k) + (dble(ua(i,j,k))-uavg(k))**2
               vvar(k) = vvar(k) + (dble(va(i,j,k))-vavg(k))**2
            enddo
         enddo
      enddo
      do k=1,nk+1
         do j=1,nj
            do i=1,ni
               wvar(k) = wvar(k) + (dble(wa(i,j,k))-wavg(k))**2
            enddo
         enddo
      enddo

#ifdef MPI
      call mpi_allreduce(mpi_in_place,uvar,nk,mpi_double_precision,mpi_sum,mpi_comm_world,ierr)
      call mpi_allreduce(mpi_in_place,vvar,nk,mpi_double_precision,mpi_sum,mpi_comm_world,ierr)
      call mpi_allreduce(mpi_in_place,wvar,nk+1,mpi_double_precision,mpi_sum,mpi_comm_world,ierr)
#endif

      do k=1,nk
         uvar(k) = uvar(k)/ngrid
         vvar(k) = vvar(k)/ngrid
      enddo
      do k=1,nk+1
         wvar(k) = wvar(k)/ngrid
      enddo

      ! Form the horizontally averaged SGS turbulence fraction on w levels.
      ! The u/v resolved variances are averaged from adjacent scalar levels.
      do k=2,nk
         er_w = 0.25d0*(uvar(k-1)+uvar(k)) + 0.25d0*(vvar(k-1)+vvar(k)) &
              + 0.5d0*wvar(k)
         denom = esavg(k) + er_w
         if (denom.gt.0.0d0) fs_sgs(k) = real(max(0.0d0,min(1.0d0,esavg(k)/denom)))
      enddo
      fs_sgs(1) = 0.0
      fs_sgs(nk+1) = 0.0

      if (.not.allocated(sfs_fs_profile)) allocate(sfs_fs_profile(1:nk+1))
      do k=1,nk+1
         sfs_fs_profile(k) = fs_sgs(k)
      enddo

      end subroutine compute_sfs_fs_profile

      subroutine interpolate_sfs_position_fields(iflag,jflag,kflag,x3d,y3d,z3d,sig3d, &
                                                 khhval,khvval,dkhvdzval, &
                                                 xh,yh,zf,sigmaf,khh,khv)
      !$acc routine seq
      use input, only : ib,ie,jb,je,kb,ke,ibc,iec,jbc,jec,kbc,kec, &
                        ni,nj,nkp1,terrain_flag
      use parcel_module
      implicit none

      integer, intent(in) :: iflag,jflag,kflag
      real, intent(in) :: x3d,y3d,z3d,sig3d
      real, intent(out) :: khhval,khvval,dkhvdzval
      real, intent(in), dimension(ib:ie) :: xh
      real, intent(in), dimension(jb:je) :: yh
      real, intent(in), dimension(ib:ie,jb:je,kb:ke+1) :: zf
      real, intent(in), dimension(kb:ke+1) :: sigmaf
      real, intent(in), dimension(ibc:iec,jbc:jec,kbc:kec) :: khh,khv

      integer :: i,j,k
      real :: rx,ry,rz,w1,w2,w3,w4,w5,w6,w7,w8
      real :: wxy1,wxy2,wxy3,wxy4,khv_bot,khv_top,dzloc

      i = iflag
      j = jflag
      k = kflag

      if( x3d.lt.xh(i) )then
        i = i-1
      endif
      if( y3d.lt.yh(j) )then
        j = j-1
      endif

      ! CM1 locates kh at w points: scalar x/y, full-level z/sigma.
      rx = ( x3d-xh(i) )/( xh(i+1)-xh(i) )
      ry = ( y3d-yh(j) )/( yh(j+1)-yh(j) )
      if( .not. terrain_flag )then
        rz = ( z3d-zf(iflag,jflag,k) )/( zf(iflag,jflag,k+1)-zf(iflag,jflag,k) )
      else
        rz = ( sig3d-sigmaf(k) )/( sigmaf(k+1)-sigmaf(k) )
      endif

      w1 = (1.0-rx)*(1.0-ry)*(1.0-rz)
      w2 = rx*(1.0-ry)*(1.0-rz)
      w3 = (1.0-rx)*ry*(1.0-rz)
      w4 = (1.0-rx)*(1.0-ry)*rz
      w5 = rx*(1.0-ry)*rz
      w6 = (1.0-rx)*ry*rz
      w7 = rx*ry*(1.0-rz)
      w8 = rx*ry*rz

      khhval = tri_interp(ni,nj,nkp1,i,j,k,w1,w2,w3,w4,w5,w6,w7,w8,khh)
      khvval = tri_interp(ni,nj,nkp1,i,j,k,w1,w2,w3,w4,w5,w6,w7,w8,khv)

      wxy1 = (1.0-rx)*(1.0-ry)
      wxy2 = rx*(1.0-ry)
      wxy3 = (1.0-rx)*ry
      wxy4 = rx*ry
      khv_bot = khv(i  ,j  ,k  )*wxy1 + khv(i+1,j  ,k  )*wxy2 &
              + khv(i  ,j+1,k  )*wxy3 + khv(i+1,j+1,k  )*wxy4
      khv_top = khv(i  ,j  ,k+1)*wxy1 + khv(i+1,j  ,k+1)*wxy2 &
              + khv(i  ,j+1,k+1)*wxy3 + khv(i+1,j+1,k+1)*wxy4
      dzloc = max(zf(iflag,jflag,k+1)-zf(iflag,jflag,k),1.0e-6)
      dkhvdzval = (khv_top-khv_bot)/dzloc

      end subroutine interpolate_sfs_position_fields

      subroutine interpolate_sfs_velocity_fields(iflag,jflag,kflag,x3d,y3d,z3d,sig3d, &
                                                 sigsgsval,dsgsdxval,dsgsdyval,dsgsdzval, &
                                                 epssgsval,lsgsval,fsval, &
                                                 xh,yh,zf,sigmaf,tkea,dissten,fs_sgs)
      !$acc routine seq
      use input, only : ib,ie,jb,je,kb,ke,ibt,iet,jbt,jet,kbt,ket,terrain_flag
      implicit none

      integer, intent(in) :: iflag,jflag,kflag
      real, intent(in) :: x3d,y3d,z3d,sig3d
      real, intent(out) :: sigsgsval,dsgsdxval,dsgsdyval,dsgsdzval
      real, intent(out) :: epssgsval,lsgsval,fsval
      real, intent(in), dimension(ib:ie) :: xh
      real, intent(in), dimension(jb:je) :: yh
      real, intent(in), dimension(ib:ie,jb:je,kb:ke+1) :: zf,dissten
      real, intent(in), dimension(kb:ke+1) :: sigmaf
      real, intent(in), dimension(ibt:iet,jbt:jet,kbt:ket) :: tkea
      real, intent(in), dimension(kb:ke+1) :: fs_sgs

      integer :: i,j,k
      real :: rx,ry,rz,dxloc,dyloc,dzloc
      real :: w1,w2,w3,w4,w5,w6,w7,w8
      real :: s1,s2,s3,s4,s5,s6,s7,s8

      i = iflag
      j = jflag
      k = kflag

      if( x3d.lt.xh(i) )then
        i = i-1
      endif
      if( y3d.lt.yh(j) )then
        j = j-1
      endif

      ! CM1 locates tke and dissipation at w points: scalar x/y, full-level z/sigma.
      dxloc = max(xh(i+1)-xh(i),1.0e-6)
      dyloc = max(yh(j+1)-yh(j),1.0e-6)
      dzloc = max(zf(iflag,jflag,k+1)-zf(iflag,jflag,k),1.0e-6)
      rx = ( x3d-xh(i) )/dxloc
      ry = ( y3d-yh(j) )/dyloc
      if( .not. terrain_flag )then
        rz = ( z3d-zf(iflag,jflag,k) )/dzloc
      else
        rz = ( sig3d-sigmaf(k) )/( sigmaf(k+1)-sigmaf(k) )
      endif

      w1 = (1.0-rx)*(1.0-ry)*(1.0-rz)
      w2 = rx*(1.0-ry)*(1.0-rz)
      w3 = (1.0-rx)*ry*(1.0-rz)
      w4 = (1.0-rx)*(1.0-ry)*rz
      w5 = rx*(1.0-ry)*rz
      w6 = (1.0-rx)*ry*rz
      w7 = rx*ry*(1.0-rz)
      w8 = rx*ry*rz

      s1 = (2.0/3.0)*max(tkea(i  ,j  ,k  ),0.0)
      s2 = (2.0/3.0)*max(tkea(i+1,j  ,k  ),0.0)
      s3 = (2.0/3.0)*max(tkea(i  ,j+1,k  ),0.0)
      s4 = (2.0/3.0)*max(tkea(i  ,j  ,k+1),0.0)
      s5 = (2.0/3.0)*max(tkea(i+1,j  ,k+1),0.0)
      s6 = (2.0/3.0)*max(tkea(i  ,j+1,k+1),0.0)
      s7 = (2.0/3.0)*max(tkea(i+1,j+1,k  ),0.0)
      s8 = (2.0/3.0)*max(tkea(i+1,j+1,k+1),0.0)

      sigsgsval = s1*w1 + s2*w2 + s3*w3 + s4*w4 + s5*w5 + s6*w6 + s7*w7 + s8*w8
      ! These are derivatives of the local trilinear sigsgs interpolant,
      ! evaluated at the particle position, not interpolated gradient fields.
      dsgsdxval = ((1.0-ry)*(1.0-rz)*(s2-s1) + (1.0-ry)*rz*(s5-s4) &
                 + ry*(1.0-rz)*(s7-s3) + ry*rz*(s8-s6))/dxloc
      dsgsdyval = ((1.0-rx)*(1.0-rz)*(s3-s1) + (1.0-rx)*rz*(s6-s4) &
                 + rx*(1.0-rz)*(s7-s2) + rx*rz*(s8-s5))/dyloc
      dsgsdzval = ((1.0-rx)*(1.0-ry)*(s4-s1) + rx*(1.0-ry)*(s5-s2) &
                 + (1.0-rx)*ry*(s6-s3) + rx*ry*(s8-s7))/dzloc

      epssgsval = dissten(i  ,j  ,k  )*w1 + dissten(i+1,j  ,k  )*w2 &
                + dissten(i  ,j+1,k  )*w3 + dissten(i  ,j  ,k+1)*w4 &
                + dissten(i+1,j  ,k+1)*w5 + dissten(i  ,j+1,k+1)*w6 &
                + dissten(i+1,j+1,k  )*w7 + dissten(i+1,j+1,k+1)*w8
      epssgsval = max(epssgsval,0.0)
      lsgsval = (2.25*dxloc*dyloc*dzloc)**(1.0/3.0)
      fsval = (1.0-rz)*fs_sgs(k) + rz*fs_sgs(k+1)
      fsval = max(0.0,min(1.0,fsval))

      end subroutine interpolate_sfs_velocity_fields

      subroutine sfs_position_update(dt,nstep,mtime,np,seed_base,pdata, &
                                     x3d,y3d,z3d,khhval,khvval,dkhvdzval)
      !$acc routine seq
      use input, only : nparcelsLocal,npvals,nx,ny,axisymm
      use constants, only : i8,pi
      implicit none

      real, intent(in) :: dt,khhval,khvval,dkhvdzval
      double precision, intent(in) :: mtime
      integer, intent(in) :: nstep,np
      integer(i8), intent(in) :: seed_base
      real, intent(inout) :: x3d,y3d,z3d
      real, intent(in), dimension(nparcelsLocal,npvals) :: pdata

      integer(i8) :: seed,state
      integer(i8), parameter :: im = 2147483647_i8
      real :: khh_eff,khv_eff
      real :: normx,normy,normz
      double precision :: u1,u2,fac,theta

      ! Deterministic per-particle seed: particle ID, creator rank, step, and time.
      seed = mod(1_i8 + seed_base,im)
      seed = mod(seed + abs(int(nstep,i8))*1013_i8,im)
      seed = mod(seed + abs(int(1000.0d0*mtime+0.5d0,i8))*37_i8,im)
      if( seed.le.0_i8 ) seed = 1_i8
      state = seed

      ! Box-Muller transform: two uniform draws give x/y standard normals.
      u1 = max(sfs_uniform(state),1.0d-12)
      u2 = sfs_uniform(state)
      fac = sqrt(-2.0d0*log(u1))
      theta = 2.0d0*dble(pi)*u2
      normx = real(fac*cos(theta))
      normy = real(fac*sin(theta))

      ! A second Box-Muller pair supplies the vertical standard normal.
      u1 = max(sfs_uniform(state),1.0d-12)
      u2 = sfs_uniform(state)
      fac = sqrt(-2.0d0*log(u1))
      theta = 2.0d0*dble(pi)*u2
      normz = real(fac*cos(theta))

      khh_eff = max(khhval,0.0)
      khv_eff = max(khvval,0.0)

      if( nx.gt.1 .and. axisymm.ne.1 )then
        x3d = x3d + normx*sqrt(2.0*khh_eff*dt)
      endif
      if( ny.gt.1 .and. axisymm.ne.1 )then
        y3d = y3d + normy*sqrt(2.0*khh_eff*dt)
      endif
      z3d = z3d + normz*sqrt(2.0*khv_eff*dt) + dkhvdzval*dt

      end subroutine sfs_position_update

      subroutine sfs_velocity_update(dt,nstep,mtime,np,seed_base,pdata, &
                                     x3d,y3d,z3d,sigsgsval, &
                                     dsgsdxval,dsgsdyval,dsgsdzval, &
                                     epssgsval,lsgsval,fsval,dlogsig_abs,dlogsig_valid)
      !$acc routine seq
      use input, only : nparcelsLocal,npvals,nx,ny,axisymm, &
                        prusgs,prvsgs,prwsgs,prsigsgs
      use constants, only : i8,pi
      implicit none

      real, intent(in) :: dt,sigsgsval,dsgsdxval,dsgsdyval,dsgsdzval
      real, intent(in) :: epssgsval,lsgsval,fsval
      double precision, intent(in) :: mtime
      integer, intent(in) :: nstep,np
      integer(i8), intent(in) :: seed_base
      integer, intent(out) :: dlogsig_valid
      real, intent(inout) :: x3d,y3d,z3d
      real, intent(out) :: dlogsig_abs
      real, intent(inout), dimension(nparcelsLocal,npvals) :: pdata

      integer(i8) :: seed,state
      integer(i8), parameter :: im = 2147483647_i8
      real, parameter :: c0 = 6.0
      real :: sig_eff,sig_prev,eps_eff,l_eff,fs_eff,noise_amp
      real :: normx,normy,normz
      real :: us_old,vs_old,ws_old
      real :: a1,a2,a3,dsig_frac
      double precision :: u1,u2,fac,theta

      dlogsig_abs = 0.0
      dlogsig_valid = 0

      if( dt.le.0.0 ) return

      if( sigsgsval.le.0.0 )then
        pdata(np,prusgs) = 0.0
        pdata(np,prvsgs) = 0.0
        pdata(np,prwsgs) = 0.0
        pdata(np,prsigsgs) = 0.0
        return
      endif

      sig_eff = max(abs(sigsgsval),1.0e-4)
      sig_prev = pdata(np,prsigsgs)
      if( sig_prev.le.0.0 )then
        sig_prev = sig_eff
      else
        sig_prev = max(abs(sig_prev),1.0e-4)
      endif

      l_eff = max(lsgsval,1.0e-6)
      fs_eff = max(0.0,min(1.0,fsval))
      eps_eff = epssgsval
      if( eps_eff.le.0.0 )then
        eps_eff = (0.93/l_eff)*(1.5*sig_eff)**1.5
      endif
      if( eps_eff.le.0.0 )then
        pdata(np,prusgs) = 0.0
        pdata(np,prvsgs) = 0.0
        pdata(np,prwsgs) = 0.0
        pdata(np,prsigsgs) = sig_eff
        return
      endif

      ! Deterministic per-particle seed, offset from the position SGS sequence.
      seed = mod(104729_i8 + seed_base,im)
      seed = mod(seed + abs(int(nstep,i8))*1013_i8,im)
      seed = mod(seed + abs(int(1000.0d0*mtime+0.5d0,i8))*37_i8,im)
      if( seed.le.0_i8 ) seed = 1_i8
      state = seed

      ! Box-Muller transform: two uniform draws give x/y standard normals.
      u1 = max(sfs_uniform(state),1.0d-12)
      u2 = sfs_uniform(state)
      fac = sqrt(-2.0d0*log(u1))
      theta = 2.0d0*dble(pi)*u2
      normx = real(fac*cos(theta))
      normy = real(fac*sin(theta))

      ! A second Box-Muller pair supplies the vertical standard normal.
      u1 = max(sfs_uniform(state),1.0d-12)
      u2 = sfs_uniform(state)
      fac = sqrt(-2.0d0*log(u1))
      theta = 2.0d0*dble(pi)*u2
      normz = real(fac*cos(theta))

      noise_amp = sqrt(max(fs_eff*c0*eps_eff*dt,0.0))
      dsig_frac = log(sig_eff/sig_prev)
      dlogsig_abs = abs(dsig_frac)
      dlogsig_valid = 1

      ! Advance all deterministic SFS velocity terms with the same Euler step.
      ! dlogsig_abs remains a diagnostic for the sigm_s time-change term.
      us_old = pdata(np,prusgs)
      a1 = -0.5*fs_eff*c0*eps_eff*us_old/sig_eff
      a2 = 0.5*fs_eff*us_old*dsig_frac/dt
      a3 = 0.5*fs_eff*dsgsdxval
      pdata(np,prusgs) = us_old + (a1+a2+a3)*dt + noise_amp*normx

      vs_old = pdata(np,prvsgs)
      a1 = -0.5*fs_eff*c0*eps_eff*vs_old/sig_eff
      a2 = 0.5*fs_eff*vs_old*dsig_frac/dt
      a3 = 0.5*fs_eff*dsgsdyval
      pdata(np,prvsgs) = vs_old + (a1+a2+a3)*dt + noise_amp*normy

      ws_old = pdata(np,prwsgs)
      a1 = -0.5*fs_eff*c0*eps_eff*ws_old/sig_eff
      a2 = 0.5*fs_eff*ws_old*dsig_frac/dt
      a3 = 0.5*fs_eff*dsgsdzval
      pdata(np,prwsgs) = ws_old + (a1+a2+a3)*dt + noise_amp*normz

      if( nx.gt.1 .and. axisymm.ne.1 )then
        x3d = x3d + pdata(np,prusgs)*dt
      else
        pdata(np,prusgs) = 0.0
      endif
      if( ny.gt.1 .and. axisymm.ne.1 )then
        y3d = y3d + pdata(np,prvsgs)*dt
      else
        pdata(np,prvsgs) = 0.0
      endif
      z3d = z3d + pdata(np,prwsgs)*dt

      pdata(np,prsigsgs) = sig_eff

      end subroutine sfs_velocity_update

      double precision function sfs_uniform(state)
      !$acc routine seq
      use constants, only : i8
      implicit none

      ! Local scalar RNG avoids shared Mersenne Twister state inside the per-particle OpenACC path.
      integer(i8), intent(inout) :: state
      integer(i8), parameter :: im = 2147483647_i8
      integer(i8), parameter :: ia = 48271_i8

      state = mod(ia*state,im)
      if( state.le.0_i8 ) state = state + im - 1_i8
      sfs_uniform = dble(state)/dble(im)

      end function sfs_uniform

      subroutine interpolate_to_parcel(np,iflag,jflag,kflag,x3d,y3d,z3d,sig3d,uval,vval,wval,tval,qval,rhoval,prsval,xh,xf,yh,yf,zh,zf,zs,znt,sigma,sigmaf,ua,va,wa,ta,qa,rho,prs,sigdot)
      !$acc routine seq
      use input, only : ib,ie,jb,je,kb,ke,numq,nparcelsLocal,nx,ny, &
                        axisymm,terrain_flag,ni,nj,nip1,nk,nkp1, &
                        zt,rzt,imoist,nqv,bbc,imove,umove,vmove
      use constants
      use parcel_module
      implicit none

      real, intent(in), dimension(ib:ie+1) :: xf
      real, intent(in), dimension(jb:je+1) :: yf
      real, intent(in), dimension(ib:ie,jb:je,kb:ke+1) :: zf
      real, intent(in), dimension(ib:ie) :: xh
      real, intent(in), dimension(jb:je) :: yh
      real, intent(in), dimension(ib:ie,jb:je,kb:ke) :: zh
      real, intent(in), dimension(ib:ie,jb:je) :: zs
      real, intent(in), dimension(kb:ke) :: sigma
      real, intent(in), dimension(kb:ke+1) :: sigmaf
      real, intent(inout), dimension(ib:ie+1,jb:je,kb:ke) :: ua
      real, intent(inout), dimension(ib:ie,jb:je+1,kb:ke) :: va
      real, intent(inout), dimension(ib:ie,jb:je,kb:ke+1) :: wa
      real, intent(inout), dimension(ib:ie,jb:je,kb:ke,numq) :: qa
      real, intent(inout), dimension(ib:ie,jb:je,kb:ke) :: ta
      real, intent(inout), dimension(ib:ie,jb:je,kb:ke) :: rho,prs
      real, intent(in), dimension(ib:ie,jb:je) :: znt

      integer, intent(in) :: np
      integer, intent(in) :: iflag,jflag,kflag
      real, intent(inout) :: x3d,y3d,z3d,sig3d,uval,vval,wval,tval,qval,rhoval,prsval,sigdot
      real :: rx,ry,rz,w1,w2,w3,w4,w5,w6,w7,w8,wsum
      real :: rxu,ryv,rzw,rxs,rys,rzs
      real :: zsp,rznt,z0,var
      integer :: i,j,k


!----------------------------------------------------------------------
!  Data on u points

        i=iflag
        j=jflag
        k=kflag

        if( y3d.lt.yh(j) )then
          j=j-1
        endif
        if( .not. terrain_flag )then
          if( z3d.lt.zh(iflag,jflag,k) )then
            k=k-1
          endif
          rz = ( z3d-zh(iflag,jflag,k) )/( zh(iflag,jflag,k+1)-zh(iflag,jflag,k) )
        else
          if( sig3d.lt.sigma(k) )then
            k=k-1
          endif
          rz = ( sig3d-sigma(k) )/( sigma(k+1)-sigma(k) )
        endif

        rx = ( x3d-xf(i) )/( xf(i+1)-xf(i) )
        ry = ( y3d-yh(j) )/( yh(j+1)-yh(j) )

        ! saveit:
        rxu = rx
        rys = ry
        rzs = rz


        !w1 = calcW1(rx,ry,rz)
        !w2 = calcW2(rx,ry,rz)
        !w3 = calcW3(rx,ry,rz)
        !w4 = calcW4(rx,ry,rz)
        !w5 = calcW5(rx,ry,rz)
        !w6 = calcW6(rx,ry,rz)
        !w7 = calcW7(rx,ry,rz)
        !w8 = calcW8(rx,ry,rz)

        w1 = (1.0-rx)*(1.0-ry)*(1.0-rz)
        w2 = rx*(1.0-ry)*(1.0-rz)
        w3 = (1.0-rx)*ry*(1.0-rz)
        w4 = (1.0-rx)*(1.0-ry)*rz
        w5 = rx*(1.0-ry)*rz
        w6 = (1.0-rx)*ry*rz
        w7 = rx*ry*(1.0-rz)
        w8 = rx*ry*rz

        uval = tri_interp(nip1,nj,nk,i,j,k,w1,w2,w3,w4,w5,w6,w7,w8,ua)
        ! uval = ua(i  ,j  ,k  )*w1 &
        !      + ua(i+1,j  ,k  )*w2 &
        !      + ua(i  ,j+1,k  )*w3 &
        !      + ua(i  ,j  ,k+1)*w4 &
        !      + ua(i+1,j  ,k+1)*w5 &
        !      + ua(i  ,j+1,k+1)*w6 &
        !      + ua(i+1,j+1,k  )*w7 &
        !      + ua(i+1,j+1,k+1)*w8

!----------------------------------------------------------------------
!  Data on v points

        !print *,'parcel: data on v-points'
        i=iflag
        j=jflag
        k=kflag

        if( x3d.lt.xh(i) )then
          i=i-1
        endif
        if( .not. terrain_flag )then
          if( z3d.lt.zh(iflag,jflag,k) )then
            k=k-1
          endif
        else
          if( sig3d.lt.sigma(k) )then
            k=k-1
          endif
        endif

        rx = ( x3d-xh(i) )/( xh(i+1)-xh(i) )
        ry = ( y3d-yf(j) )/( yf(j+1)-yf(j) )
        rz = rzs

        ! saveit:
        rxs = rx
        ryv = ry

        !w1 = calcW1(rx,ry,rz)
        !w2 = calcW2(rx,ry,rz)
        !w3 = calcW3(rx,ry,rz)
        !w4 = calcW4(rx,ry,rz)
        !w5 = calcW5(rx,ry,rz)
        !w6 = calcW6(rx,ry,rz)
        !w7 = calcW7(rx,ry,rz)
        !!w8 = calcW8(rx,ry,rz)
        w1 = (1.0-rx)*(1.0-ry)*(1.0-rz)
        w2 = rx*(1.0-ry)*(1.0-rz)
        w3 = (1.0-rx)*ry*(1.0-rz)
        w4 = (1.0-rx)*(1.0-ry)*rz
        w5 = rx*(1.0-ry)*rz
        w6 = (1.0-rx)*ry*rz
        w7 = rx*ry*(1.0-rz)
        w8 = rx*ry*rz
        vval = tri_interp(ni,nj+1,nk,i,j,k,w1,w2,w3,w4,w5,w6,w7,w8,va)
        ! vval = va(i  ,j  ,k  )*w1 &
        !      + va(i+1,j  ,k  )*w2 &
        !      + va(i  ,j+1,k  )*w3 &
        !      + va(i  ,j  ,k+1)*w4 &
        !      + va(i+1,j  ,k+1)*w5 &
        !      + va(i  ,j+1,k+1)*w6 &
        !      + va(i+1,j+1,k  )*w7 &
        !      + va(i+1,j+1,k+1)*w8


!----------------------------------------------------------------------
!  Data on w points

        i=iflag
        j=jflag
        k=kflag

        if( x3d.lt.xh(i) )then
          i=i-1
        endif
        if( y3d.lt.yh(j) )then
          j=j-1
        endif

        rx = rxs
        ry = rys
        if( .not. terrain_flag )then
          rz = ( z3d-zf(iflag,jflag,k) )/( zf(iflag,jflag,k+1)-zf(iflag,jflag,k) )
        else
          rz = ( sig3d-sigmaf(k) )/( sigmaf(k+1)-sigmaf(k) )
        endif

        ! saveit:
        rzw = rz

        !w1 = calcW1(rx,ry,rz)
        !w2 = calcW2(rx,ry,rz)
        !w3 = calcW3(rx,ry,rz)
        !w4 = calcW4(rx,ry,rz)
        !w5 = calcW5(rx,ry,rz)
        !w6 = calcW6(rx,ry,rz)
        !w7 = calcW7(rx,ry,rz)
        !w8 = calcW8(rx,ry,rz)
        w1 = (1.0-rx)*(1.0-ry)*(1.0-rz)
        w2 = rx*(1.0-ry)*(1.0-rz)
        w3 = (1.0-rx)*ry*(1.0-rz)
        w4 = (1.0-rx)*(1.0-ry)*rz
        w5 = rx*(1.0-ry)*rz
        w6 = (1.0-rx)*ry*rz
        w7 = rx*ry*(1.0-rz)
        w8 = rx*ry*rz
        wval = tri_interp(ni,nj,nkp1,i,j,k,w1,w2,w3,w4,w5,w6,w7,w8,wa)
        ! wval = wa(i  ,j  ,k  )*w1 &
        !      + wa(i+1,j  ,k  )*w2 &
        !      + wa(i  ,j+1,k  )*w3 &
        !      + wa(i  ,j  ,k+1)*w4 &
        !      + wa(i+1,j  ,k+1)*w5 &
        !      + wa(i  ,j+1,k+1)*w6 &
        !      + wa(i+1,j+1,k  )*w7 &
        !      + wa(i+1,j+1,k+1)*w8

        if( terrain_flag )then
          sigdot = tri_interp(ni,nj,nkp1,i,j,k,w1,w2,w3,w4,w5,w6,w7,w8,wa)
          ! sigdot = wa(i  ,j  ,k  )*w1 &
          !    + wa(i+1,j  ,k  )*w2 &
          !    + wa(i  ,j+1,k  )*w3 &
          !    + wa(i  ,j  ,k+1)*w4 &
          !    + wa(i+1,j  ,k+1)*w5 &
          !    + wa(i  ,j+1,k+1)*w6 &
          !    + wa(i+1,j+1,k  )*w7 &
          !    + wa(i+1,j+1,k+1)*w8
          zsp = get2d(i,j,x3d,y3d,xh,xf,yh,yf, 0, 0, 0, 0,zs)
          z3d = zsp + sig3d*((zt-zsp)*rzt)
        endif


!----------------------------------------------------------------------
!  Data on scalar points

        i=iflag
        j=jflag
        k=kflag

        if( x3d.lt.xh(i) )then
          i=i-1
        endif
        if( y3d.lt.yh(j) )then
          j=j-1
        endif
        if( .not. terrain_flag )then
          if( z3d.lt.zh(iflag,jflag,k) )then
            k=k-1
          endif
        else
          if( z3d.lt.sigma(k) )then
            k=k-1
          endif
        endif


        rx = rxs
        ry = rys
        rz = rzs

        !w1 = calcW1(rx,ry,rz)
        !w2 = calcW2(rx,ry,rz)
        !w3 = calcW3(rx,ry,rz)
        !w4 = calcW4(rx,ry,rz)
        !w5 = calcW5(rx,ry,rz)
        !w6 = calcW6(rx,ry,rz)
        !w7 = calcW7(rx,ry,rz)
        !w8 = calcW8(rx,ry,rz)
        w1 = (1.0-rx)*(1.0-ry)*(1.0-rz)
        w2 = rx*(1.0-ry)*(1.0-rz)
        w3 = (1.0-rx)*ry*(1.0-rz)
        w4 = (1.0-rx)*(1.0-ry)*rz
        w5 = rx*(1.0-ry)*rz
        w6 = (1.0-rx)*ry*rz
        w7 = rx*ry*(1.0-rz)
        w8 = rx*ry*rz

      if(imoist.eq.1)then
        !!print *,'parcel: before qval'
        qval = tri_interp(ni,nj,nk,i,j,k,w1,w2,w3,w4,w5,w6,w7,w8,qa(ib,jb,kb,nqv))
        ! qval = qa(i  ,j  ,k  ,nqv)*w1 &
        !      + qa(i+1,j  ,k  ,nqv)*w2 &
        !      + qa(i  ,j+1,k  ,nqv)*w3 &
        !      + qa(i  ,j  ,k+1,nqv)*w4 &
        !      + qa(i+1,j  ,k+1,nqv)*w5 &
        !      + qa(i  ,j+1,k+1,nqv)*w6 &
        !      + qa(i+1,j+1,k  ,nqv)*w7 &
        !      + qa(i+1,j+1,k+1,nqv)*w8
      endif
      !if(np==100) then 
      !  print *,'parcel: ngxy,ngz: ',ngxy,ngz
      !  print *,'parcel: before tval: ',i,j,k
      !endif
      tval   = tri_interp(ni,nj,nk,i,j,k,w1,w2,w3,w4,w5,w6,w7,w8,ta)
      ! tval   = ta(i  ,j  ,k  )*w1 &
      !        + ta(i+1,j  ,k  )*w2 &
      !        + ta(i  ,j+1,k  )*w3 &
      !        + ta(i  ,j  ,k+1)*w4 &
      !        + ta(i+1,j  ,k+1)*w5 &
      !        + ta(i  ,j+1,k+1)*w6 &
      !        + ta(i+1,j+1,k  )*w7 &
      !        + ta(i+1,j+1,k+1)*w8
      rhoval = tri_interp(ni,nj,nk,i,j,k,w1,w2,w3,w4,w5,w6,w7,w8,rho)
      ! rhoval = rho(i  ,j  ,k  )*w1 &
      !        + rho(i+1,j  ,k  )*w2 &
      !        + rho(i  ,j+1,k  )*w3 &
      !        + rho(i  ,j  ,k+1)*w4 &
      !        + rho(i+1,j  ,k+1)*w5 &
      !        + rho(i  ,j+1,k+1)*w6 &
      !        + rho(i+1,j+1,k  )*w7 &
      !        + rho(i+1,j+1,k+1)*w8
      prsval = tri_interp(ni,nj,nk,i,j,k,w1,w2,w3,w4,w5,w6,w7,w8,prs)
      ! prsval = prs(i  ,j  ,k  )*w1 &
      !        + prs(i+1,j  ,k  )*w2 &
      !        + prs(i  ,j+1,k  )*w3 &
      !        + prs(i  ,j  ,k+1)*w4 &
      !        + prs(i+1,j  ,k+1)*w5 &
      !        + prs(i  ,j+1,k+1)*w6 &
      !        + prs(i+1,j+1,k  )*w7 &
      !        + prs(i+1,j+1,k+1)*w8


!----------------------------------------------------------------------
!  uv for parcels below lowest model level:

      IF( bbc.eq.3 )THEN
        ! semi-slip lower boundary condition:
        if( z3d.lt.zh(1,1,1) )then
          ! re-calculate velocities if parcel is below lowest model level:
          !------
          ! u at lowest model level:
          i=iflag
          j=jflag
          if( y3d.lt.yh(j) )then
            j=j-1
          endif
          uval = get2d(i,j,x3d,y3d,xh,xf,yh,yf, 1, 0, 1, 0,ua(ib,jb,1))
          !------
          ! v at lowest model level:
          i=iflag
          j=jflag
          if( x3d.lt.xh(i) )then
            i=i-1
          endif
          vval = get2d(i,j,x3d,y3d,xh,xf,yh,yf, 0, 1, 0, 1,va(ib,jb,1))
          !------
          ! z0:
          i=iflag
          j=jflag
          if( x3d.lt.xh(i) )then
            i=i-1
          endif
          if( y3d.lt.yh(j) )then
            j=j-1
          endif
          z0 = get2d(i,j,x3d,y3d,xh,xf,yh,yf, 0, 0, 0, 0,znt)
          !------
          ! get u,v from (neutral) log-layer equation:
          rznt = 1.0/z0
          var = alog((z3d+z0)*rznt)/alog((zh(1,1,1)+z0)*rznt)
          if( imove.eq.1 )then
            uval = (uval+umove)*var - umove
            vval = (vval+vmove)*var - vmove
          else
            uval = uval*var
            vval = vval*var
          endif
        endif
      ENDIF


      end subroutine interpolate_to_parcel

      subroutine project_feedback(iflag,jflag,kflag,x3d,y3d,z3d,sig3d, &
                                  rhop0,taup0,rp0,tval, &
                                  dpten,xh,xf,yh,yf,zh,zf,sigma,  &
                                  sigmaf,sigdot,dvpdt1,dvpdt2,dvpdt3,  &
                                  drpdt,dtpdt,dmpdt,rhoval,part_grav1, &
                                  part_grav2,part_grav3,pdata,np)
      !$acc routine seq
      use input, only : ib,ie,jb,je,kb,ke,numq,nparcelsLocal,nx,ny, &
                        axisymm,terrain_flag,ni,nj,nip1,nk,nkp1, &
                        zt,rzt,imoist,nqv,bbc,imove,umove,vmove, &
                        npvals,nparcelsLocal,prrp,prms,prmult, &
                        pract,prt,viscosity,nparcelsLocalActive
      use constants
      use parcel_module
      implicit none

      real, intent(in) :: dvpdt1,dvpdt2,dvpdt3,drpdt,dtpdt,dmpdt
      real, intent(in), dimension(nparcelsLocal,npvals) :: pdata
      real, intent(in) :: part_grav1,part_grav2,part_grav3

      real, intent(in), dimension(ib:ie+1) :: xf
      real, intent(in), dimension(jb:je+1) :: yf
      real, intent(in), dimension(ib:ie,jb:je,kb:ke+1) :: zf
      real, intent(in), dimension(ib:ie) :: xh
      real, intent(in), dimension(jb:je) :: yh
      real, intent(in), dimension(ib:ie,jb:je,kb:ke) :: zh
      real, intent(in), dimension(kb:ke) :: sigma
      real, intent(in), dimension(kb:ke+1) :: sigmaf
      double precision, intent(inout), dimension(ib:ie,jb:je,kb:ke,5) :: dpten

      integer, intent(in) :: np
      integer, intent(in) :: iflag,jflag,kflag
      real, intent(in) :: x3d,y3d,z3d,sig3d,rhop0,taup0,rp0,tval,rhoval
      real :: rx,ry,rz,w1,w2,w3,w4,w5,w6,w7,w8,wsum
      real :: rxu,ryv,rzw,rxs,rys,rzs
      real :: zsp,rznt,z0,var,lhv
      real :: partmass,dV,volp,sigdot,tmpval
      integer :: i,j,k,dum

!----------------------------------------------------------------------
!  Project to u points

      i=iflag
      j=jflag
      k=kflag

      if( y3d.lt.yh(j) )then
        j=j-1
      endif
      if( .not. terrain_flag )then
        if( z3d.lt.zh(iflag,jflag,k) )then
          k=k-1
        endif
        rz = ( z3d-zh(iflag,jflag,k) )/( zh(iflag,jflag,k+1)-zh(iflag,jflag,k) )
      else
        if( sig3d.lt.sigma(k) )then
          k=k-1
        endif
        rz = ( sig3d-sigma(k) )/( sigma(k+1)-sigma(k) )
      endif

      rx = ( x3d-xf(i) )/( xf(i+1)-xf(i) )
      ry = ( y3d-yh(j) )/( yh(j+1)-yh(j) )

      ! saveit:
      rxu = rx
      rys = ry
      rzs = rz


      w1 = (1.0-rx)*(1.0-ry)*(1.0-rz)
      w2 = rx*(1.0-ry)*(1.0-rz)
      w3 = (1.0-rx)*ry*(1.0-rz)
      w4 = (1.0-rx)*(1.0-ry)*rz
      w5 = rx*(1.0-ry)*rz
      w6 = (1.0-rx)*ry*rz
      w7 = rx*ry*(1.0-rz)
      w8 = rx*ry*rz

      if (.not. terrain_flag) then
         dV = (xf(i+1)-xf(i))*(yh(j+1)-yh(j))*(zh(iflag,jflag,k+1)-zh(iflag,jflag,k))
      else
         dV = (xf(i+1)-xf(i))*(yh(j+1)-yh(j))*(sigma(k+1)-sigma(k))
      end if
      
      volp = (4.0/3.0)*pi*pdata(np,prrp)**3
      partmass = pdata(np,prms) + VolP*rhow

      !$acc atomic update
      dpten(i,j,k,3)       = dpten(i,j,k,3)       - partmass/rhoval*(dvpdt1-part_grav1)*w1/dV*pdata(np,prmult)
      !$acc atomic update
      dpten(i+1,j,k,3)     = dpten(i+1,j,k,3)     - partmass/rhoval*(dvpdt1-part_grav1)*w2/dV*pdata(np,prmult)
      !$acc atomic update
      dpten(i,j+1,k,3)     = dpten(i,j+1,k,3)     - partmass/rhoval*(dvpdt1-part_grav1)*w3/dV*pdata(np,prmult)
      !$acc atomic update
      dpten(i,j,k+1,3)     = dpten(i,j,k+1,3)     - partmass/rhoval*(dvpdt1-part_grav1)*w4/dV*pdata(np,prmult)
      !$acc atomic update
      dpten(i+1,j,k+1,3)   = dpten(i+1,j,k+1,3)   - partmass/rhoval*(dvpdt1-part_grav1)*w5/dV*pdata(np,prmult)
      !$acc atomic update
      dpten(i,j+1,k+1,3)   = dpten(i,j+1,k+1,3)   - partmass/rhoval*(dvpdt1-part_grav1)*w6/dV*pdata(np,prmult)
      !$acc atomic update
      dpten(i+1,j+1,k,3)   = dpten(i+1,j+1,k,3)   - partmass/rhoval*(dvpdt1-part_grav1)*w7/dV*pdata(np,prmult)
      !$acc atomic update
      dpten(i+1,j+1,k+1,3) = dpten(i+1,j+1,k+1,3) - partmass/rhoval*(dvpdt1-part_grav1)*w8/dV*pdata(np,prmult)

      !What interpolation is doing, for reference
      ! uval = ua(i  ,j  ,k  )*w1 &
      !      + ua(i+1,j  ,k  )*w2 &
      !      + ua(i  ,j+1,k  )*w3 &
      !      + ua(i  ,j  ,k+1)*w4 &
      !      + ua(i+1,j  ,k+1)*w5 &
      !      + ua(i  ,j+1,k+1)*w6 &
      !      + ua(i+1,j+1,k  )*w7 &
      !      + ua(i+1,j+1,k+1)*w8

!----------------------------------------------------------------------
!  Project to v points

      !print *,'parcel: data on v-points'
      i=iflag
      j=jflag
      k=kflag

      if( x3d.lt.xh(i) )then
        i=i-1
      endif
      if( .not. terrain_flag )then
        if( z3d.lt.zh(iflag,jflag,k) )then
          k=k-1
        endif
      else
        if( sig3d.lt.sigma(k) )then
          k=k-1
        endif
      endif

      rx = ( x3d-xh(i) )/( xh(i+1)-xh(i) )
      ry = ( y3d-yf(j) )/( yf(j+1)-yf(j) )
      rz = rzs

      ! saveit:
      rxs = rx
      ryv = ry

      if (.not. terrain_flag) then
         dV = (xh(i+1)-xh(i))*(yf(j+1)-yf(j))*(zh(iflag,jflag,k+1)-zh(iflag,jflag,k))
      else
         dV = (xh(i+1)-xh(i))*(yf(j+1)-yf(j))*(sigma(k+1)-sigma(k))
      end if

      w1 = (1.0-rx)*(1.0-ry)*(1.0-rz)
      w2 = rx*(1.0-ry)*(1.0-rz)
      w3 = (1.0-rx)*ry*(1.0-rz)
      w4 = (1.0-rx)*(1.0-ry)*rz
      w5 = rx*(1.0-ry)*rz
      w6 = (1.0-rx)*ry*rz
      w7 = rx*ry*(1.0-rz)
      w8 = rx*ry*rz

      !$acc atomic update
      dpten(i,j,k,4)       = dpten(i,j,k,4)       - partmass/rhoval*(dvpdt2-part_grav2)*w1/dV*pdata(np,prmult)
      !$acc atomic update
      dpten(i+1,j,k,4)     = dpten(i+1,j,k,4)     - partmass/rhoval*(dvpdt2-part_grav2)*w2/dV*pdata(np,prmult)
      !$acc atomic update
      dpten(i,j+1,k,4)     = dpten(i,j+1,k,4)     - partmass/rhoval*(dvpdt2-part_grav2)*w3/dV*pdata(np,prmult)
      !$acc atomic update
      dpten(i,j,k+1,4)     = dpten(i,j,k+1,4)     - partmass/rhoval*(dvpdt2-part_grav2)*w4/dV*pdata(np,prmult)
      !$acc atomic update
      dpten(i+1,j,k+1,4)   = dpten(i+1,j,k+1,4)   - partmass/rhoval*(dvpdt2-part_grav2)*w5/dV*pdata(np,prmult)
      !$acc atomic update
      dpten(i,j+1,k+1,4)   = dpten(i,j+1,k+1,4)   - partmass/rhoval*(dvpdt2-part_grav2)*w6/dV*pdata(np,prmult)
      !$acc atomic update
      dpten(i+1,j+1,k,4)   = dpten(i+1,j+1,k,4)   - partmass/rhoval*(dvpdt2-part_grav2)*w7/dV*pdata(np,prmult)
      !$acc atomic update
      dpten(i+1,j+1,k+1,4) = dpten(i+1,j+1,k+1,4) - partmass/rhoval*(dvpdt2-part_grav2)*w8/dV*pdata(np,prmult)

      ! vval = va(i  ,j  ,k  )*w1 &
      !      + va(i+1,j  ,k  )*w2 &
      !      + va(i  ,j+1,k  )*w3 &
      !      + va(i  ,j  ,k+1)*w4 &
      !      + va(i+1,j  ,k+1)*w5 &
      !      + va(i  ,j+1,k+1)*w6 &
      !      + va(i+1,j+1,k  )*w7 &
      !      + va(i+1,j+1,k+1)*w8

!----------------------------------------------------------------------
!  Project to w points

      i=iflag
      j=jflag
      k=kflag

      if( x3d.lt.xh(i) )then
        i=i-1
      endif
      if( y3d.lt.yh(j) )then
        j=j-1
      endif

      rx = rxs
      ry = rys
      if( .not. terrain_flag )then
        rz = ( z3d-zf(iflag,jflag,k) )/( zf(iflag,jflag,k+1)-zf(iflag,jflag,k) )
      else
        rz = ( sig3d-sigmaf(k) )/( sigmaf(k+1)-sigmaf(k) )
      endif

      ! saveit:
      rzw = rz

      if (.not. terrain_flag) then
         dV = (xh(i+1)-xh(i))*(yh(j+1)-yh(j))*(zf(iflag,jflag,k+1)-zf(iflag,jflag,k))
      else
         dV = (xh(i+1)-xh(i))*(yh(j+1)-yh(j))*(sigmaf(k+1)-sigmaf(k))
      end if

      w1 = (1.0-rx)*(1.0-ry)*(1.0-rz)
      w2 = rx*(1.0-ry)*(1.0-rz)
      w3 = (1.0-rx)*ry*(1.0-rz)
      w4 = (1.0-rx)*(1.0-ry)*rz
      w5 = rx*(1.0-ry)*rz
      w6 = (1.0-rx)*ry*rz
      w7 = rx*ry*(1.0-rz)
      w8 = rx*ry*rz

      !$acc atomic update
      dpten(i,j,k,5)       = dpten(i,j,k,5)       - partmass/rhoval*(dvpdt3-part_grav3)*w1/dV*pdata(np,prmult)
      !$acc atomic update
      dpten(i+1,j,k,5)     = dpten(i+1,j,k,5)     - partmass/rhoval*(dvpdt3-part_grav3)*w2/dV*pdata(np,prmult)
      !$acc atomic update
      dpten(i,j+1,k,5)     = dpten(i,j+1,k,5)     - partmass/rhoval*(dvpdt3-part_grav3)*w3/dV*pdata(np,prmult)
      !$acc atomic update
      dpten(i,j,k+1,5)     = dpten(i,j,k+1,5)     - partmass/rhoval*(dvpdt3-part_grav3)*w4/dV*pdata(np,prmult)
      !$acc atomic update
      dpten(i+1,j,k+1,5)   = dpten(i+1,j,k+1,5)   - partmass/rhoval*(dvpdt3-part_grav3)*w5/dV*pdata(np,prmult)
      !$acc atomic update
      dpten(i,j+1,k+1,5)   = dpten(i,j+1,k+1,5)   - partmass/rhoval*(dvpdt3-part_grav3)*w6/dV*pdata(np,prmult)
      !$acc atomic update
      dpten(i+1,j+1,k,5)   = dpten(i+1,j+1,k,5)   - partmass/rhoval*(dvpdt3-part_grav3)*w7/dV*pdata(np,prmult)
      !$acc atomic update
      dpten(i+1,j+1,k+1,5) = dpten(i+1,j+1,k+1,5) - partmass/rhoval*(dvpdt3-part_grav3)*w8/dV*pdata(np,prmult)

      ! wval = wa(i  ,j  ,k  )*w1 &
      !      + wa(i+1,j  ,k  )*w2 &
      !      + wa(i  ,j+1,k  )*w3 &
      !      + wa(i  ,j  ,k+1)*w4 &
      !      + wa(i+1,j  ,k+1)*w5 &
      !      + wa(i  ,j+1,k+1)*w6 &
      !      + wa(i+1,j+1,k  )*w7 &
      !      + wa(i+1,j+1,k+1)*w8

!----------------------------------------------------------------------
!  Project to scalar points

      i=iflag
      j=jflag
      k=kflag

      if( x3d.lt.xh(i) )then
        i=i-1
      endif
      if( y3d.lt.yh(j) )then
        j=j-1
      endif
      if( .not. terrain_flag )then
        if( z3d.lt.zh(iflag,jflag,k) )then
          k=k-1
        endif
      else
        if( z3d.lt.sigma(k) )then
          k=k-1
        endif
      endif


      rx = rxs
      ry = rys
      rz = rzs

      if (.not. terrain_flag) then
         dV = (xh(i+1)-xh(i))*(yh(j+1)-yh(j))*(zh(iflag,jflag,k+1)-zh(iflag,jflag,k))
      else
         dV = (xh(i+1)-xh(i))*(yh(j+1)-yh(j))*(sigma(k+1)-sigma(k))
      end if

      w1 = (1.0-rx)*(1.0-ry)*(1.0-rz)
      w2 = rx*(1.0-ry)*(1.0-rz)
      w3 = (1.0-rx)*ry*(1.0-rz)
      w4 = (1.0-rx)*(1.0-ry)*rz
      w5 = rx*(1.0-ry)*rz
      w6 = (1.0-rx)*ry*rz
      w7 = rx*ry*(1.0-rz)
      w8 = rx*ry*rz

      if(imoist.eq.1)then
        !$acc atomic update
        dpten(i,j,k,2)       = dpten(i,j,k,2)       - dmpdt/rhoval/dV*w1*pdata(np,prmult)
        !$acc atomic update
        dpten(i+1,j,k,2)     = dpten(i+1,j,k,2)     - dmpdt/rhoval/dV*w2*pdata(np,prmult)
        !$acc atomic update
        dpten(i,j+1,k,2)     = dpten(i,j+1,k,2)     - dmpdt/rhoval/dV*w3*pdata(np,prmult)
        !$acc atomic update
        dpten(i,j,k+1,2)     = dpten(i,j,k+1,2)     - dmpdt/rhoval/dV*w4*pdata(np,prmult)
        !$acc atomic update
        dpten(i+1,j,k+1,2)   = dpten(i+1,j,k+1,2)   - dmpdt/rhoval/dV*w5*pdata(np,prmult)
        !$acc atomic update
        dpten(i,j+1,k+1,2)   = dpten(i,j+1,k+1,2)   - dmpdt/rhoval/dV*w6*pdata(np,prmult)
        !$acc atomic update
        dpten(i+1,j+1,k,2)   = dpten(i+1,j+1,k,2)   - dmpdt/rhoval/dV*w7*pdata(np,prmult)
        !$acc atomic update
        dpten(i+1,j+1,k+1,2) = dpten(i+1,j+1,k+1,2) - dmpdt/rhoval/dV*w8*pdata(np,prmult)

        ! qval = qa(i  ,j  ,k  ,nqv)*w1 &
        !      + qa(i+1,j  ,k  ,nqv)*w2 &
        !      + qa(i  ,j+1,k  ,nqv)*w3 &
        !      + qa(i  ,j  ,k+1,nqv)*w4 &
        !      + qa(i+1,j  ,k+1,nqv)*w5 &
        !      + qa(i  ,j+1,k+1,nqv)*w6 &
        !      + qa(i+1,j+1,k  ,nqv)*w7 &
        !      + qa(i+1,j+1,k+1,nqv)*w8
      endif

      lhv=lv1-lv2*pdata(np,prt)

      !$acc atomic update
      dpten(i,j,k,1)       = dpten(i,j,k,1) - (dtpdt - 3*lhv/cpl/rp0*drpdt)*6.0*(rhow/rhop0)*(cpl/cp)*taup0*pi*rp0*viscosity*w1/dV*pdata(np,prmult)

      !$acc atomic update
      dpten(i+1,j,k,1)     = dpten(i+1,j,k,1) - (dtpdt - 3*lhv/cpl/rp0*drpdt)*6.0*(rhow/rhop0)*(cpl/cp)*taup0*pi*rp0*viscosity*w2/dV*pdata(np,prmult)

      !$acc atomic update
      dpten(i,j+1,k,1)     = dpten(i,j+1,k,1) - (dtpdt - 3*lhv/cpl/rp0*drpdt)*6.0*(rhow/rhop0)*(cpl/cp)*taup0*pi*rp0*viscosity*w3/dV*pdata(np,prmult)

      !$acc atomic update
      dpten(i,j,k+1,1)     = dpten(i,j,k+1,1) - (dtpdt - 3*lhv/cpl/rp0*drpdt)*6.0*(rhow/rhop0)*(cpl/cp)*taup0*pi*rp0*viscosity*w4/dV*pdata(np,prmult)

      !$acc atomic update
      dpten(i+1,j,k+1,1)   = dpten(i+1,j,k+1,1) - (dtpdt - 3*lhv/cpl/rp0*drpdt)*6.0*(rhow/rhop0)*(cpl/cp)*taup0*pi*rp0*viscosity*w5/dV*pdata(np,prmult)

      !$acc atomic update
      dpten(i,j+1,k+1,1)   = dpten(i,j+1,k+1,1) - (dtpdt - 3*lhv/cpl/rp0*drpdt)*6.0*(rhow/rhop0)*(cpl/cp)*taup0*pi*rp0*viscosity*w6/dV*pdata(np,prmult)

      !$acc atomic update
      dpten(i+1,j+1,k,1)   = dpten(i+1,j+1,k,1) - (dtpdt - 3*lhv/cpl/rp0*drpdt)*6.0*(rhow/rhop0)*(cpl/cp)*taup0*pi*rp0*viscosity*w7/dV*pdata(np,prmult)

      !$acc atomic update
      dpten(i+1,j+1,k+1,1) = dpten(i+1,j+1,k+1,1) - (dtpdt - 3*lhv/cpl/rp0*drpdt)*6.0*(rhow/rhop0)*(cpl/cp)*taup0*pi*rp0*viscosity*w8/dV*pdata(np,prmult)

      ! tval   = ta(i  ,j  ,k  )*w1 &
      !        + ta(i+1,j  ,k  )*w2 &
      !        + ta(i  ,j+1,k  )*w3 &
      !        + ta(i  ,j  ,k+1)*w4 &
      !        + ta(i+1,j  ,k+1)*w5 &
      !        + ta(i  ,j+1,k+1)*w6 &
      !        + ta(i+1,j+1,k  )*w7 &
      !        + ta(i+1,j+1,k+1)*w8

      end subroutine project_feedback

      subroutine droplet_diag(rtime,nrec,zh,zf,pdata,pdata_locind,dpten,wa,qa,th_in,th0,pi0,ppa,rho)

      use input
      use constants
      use cm1libs , only : eslf
#ifdef MPI
      use mpi
#endif
      implicit none

      integer, intent(inout) :: nrec
      real, intent(in) :: rtime
      double precision, intent(in), dimension(ib:ie,jb:je,kb:ke,5) :: dpten
      real, intent(in), dimension(nparcelsLocal,npvals) :: pdata
      integer, intent(inout), dimension(nparcelsLocal,3) :: pdata_locind    ! x/y/z location index of each parcel
      real, intent(in), dimension(ib:ie,jb:je,kb:ke) :: zh
      real, intent(in), dimension(ib:ie,jb:je,kb:ke+1) :: zf
      real, intent(in), dimension(ib:ie,jb:je,kb:ke+1) :: wa
      real, intent(in), dimension(ib:ie,jb:je,kb:ke,numq) :: qa
      real, intent(inout), dimension(ib:ie,jb:je,kb:ke) :: pi0,th0,th_in,ppa,rho

      integer :: np,iz,i,j,k,ir
      integer :: kflag
      integer(i8) :: np_tmp_diag
      !real :: dumzh(kb:ke),dumzf(kb:ke+1),dzf,xl,yl
      real :: dumzh(1:nk),dumzf(kb:ke+1),dzf,xl,yl
      real :: Tpsrc_tmp,qvsrc_tmp,m1src_tmp,m2src_tmp,m3src_tmp,rhovsrc_tmp
      real :: kmoist_tmp,wk_tmp,qt,lhv,ta_tmp,winterp_tmp,mse_tmp

      real :: radavg,radsqr,radmin,radmax,Tpavg,Tpmin,Tpmax,Tpsqr, &
              Tfavg,qfavg,prsavg,rhoavg,tnummult,tnumdrop, &
              tnumaerosol,tnumpart,tmasspart

      real :: partnum(nk),multnum(nk),partmass(nk),numconc(nk),sd_numconc(nk),massconc(nk),vp1mean(nk),vp2mean(nk),vp3mean(nk),vp1msqr(nk),vp2msqr(nk),vp3msqr(nk),uf1mean(nk),uf2mean(nk),uf3mean(nk),Tpsrc(nk),qvsrc(nk),rhovsrc(nk),qf(nk),Tf(nk),radmean(nk),radmsqr(nk),Tpmean(nk),Tpmsqr(nk),qfsat(nk),m1src(nk),m2src(nk),m3src(nk),qstarmean(nk),kmoist(nk),mse(nk),wk(nk),wtmp(nk)
      real :: usgsmean(nk),vsgsmean(nk),wsgsmean(nk),sigm_smean(nk),fsmean(nk)
      double precision, dimension(nk) :: qstardp,radmsqrdp

      real :: partnumrz(nk,nbins),multnumrz(nk,nbins),vp3meanrz(nk,nbins)

      real :: tnumpart_r(nbins)

      integer, parameter :: num0 = 33, num1 = 34   !Number of 0th and 1st order statistics in droplet_diag
      real :: rad10_tmp,dry_rad10_tmp
      double precision :: qstar_tmp
      integer :: ibin,ibin_dry

#ifdef MPI
      double precision, dimension(num0) :: droplet_diag0     ! temporary array for MPI reduce operation for the 0th-order diagnostic except rtime
      double precision, dimension(nk,num1) :: droplet_diag1     ! temporary array for MPI reduce operation for the 0th-order diagnostic except rtime
#endif

      !Compute the various types of droplet statistics

      !!!!! update module variable first !!!!!

      !$acc update host (num_destroyed,mass_destroyed,mass_evap,mass_dpten,eng_destroyed,m1_destroyed,m2_destroyed, &
      !$acc              num_injected,mass_injected,eng_injected,m1_injected,m2_injected, &
      !$acc              mass_reentry,eng_reentry,m1_reentry,m2_reentry, &
      !$acc              num100,num1000)

      !$acc data create (dumzh,dumzf,partnum,multnum,partmass,numconc,massconc,Tpsrc,qvsrc,rhovsrc,qf, &
      !$acc              Tf,radmean,Tpmean,qfsat,vp1mean,vp2mean, &
      !$acc              vp3mean,vp1msqr,vp2msqr,vp3msqr,radmsqrdp, &
      !$acc              uf1mean,uf2mean,uf3mean, &
      !$acc              usgsmean,vsgsmean,wsgsmean,sigm_smean, &
      !$acc              Tpmsqr,m1src,m2src,m3src,qstardp,kmoist,mse,wk,wtmp, &
      !$acc              partnumrz,multnumrz,vp3meanrz,tnumpart_r) 

      !!!!!!! 0th order  !!!!!!!!

      np_tmp_diag = nparcelsLocalActive
      tnumpart = real(np_tmp_diag)
      tnumaerosol = 0.0
      tnumdrop = 0.0
      tnummult = 0.0
      tmasspart = 0.0
      radavg = 0.0
      radsqr = 0.0
      Tpavg = 0.0
      Tpsqr = 0.0
      Tfavg = 0.0
      qfavg = 0.0
      prsavg = 0.0
      rhoavg = 0.0
      radmin = 1000.0
      radmax = -1000.0
      Tpmin = 1000.0
      Tpmax = -1000.0

      !$acc parallel loop gang vector default(present) &
      !$acc          reduction(+:tnummult,tmasspart,tnumaerosol,tnumdrop,radavg,radsqr,Tpavg,Tpsqr,Tfavg,qfavg,prsavg,rhoavg) &
      !$acc          reduction(max:radmax,Tpmax) &
      !$acc          reduction(min:radmin,Tpmin)
      do np=1,nparcelsLocalActive
         tnummult = tnummult + pdata(np,prmult)
         tmasspart = tmasspart + (rhow*4.0/3.0*pi*pdata(np,prrp)**3)*pdata(np,prmult)
         if (pdata(np,prrp) .lt. crit_radius(pdata(np,prms),pdata(np,prkap),pdata(np,prt))) then
             tnumaerosol = tnumaerosol + pdata(np,prmult)
         else
             tnumdrop = tnumdrop + pdata(np,prmult)
         end if
         radavg = radavg + pdata(np,prrp)
         radsqr = radsqr + pdata(np,prrp)**2
         Tpavg = Tpavg + pdata(np,prtp)
         Tpsqr = Tpsqr + pdata(np,prtp)**2 
         Tfavg = Tfavg + pdata(np,prt)
         qfavg = qfavg + pdata(np,prqv)
         prsavg = prsavg + pdata(np,prprs)
         rhoavg = rhoavg + pdata(np,prrho)

         radmin = min(radmin, pdata(np,prrp))
         radmax = max(radmax, pdata(np,prrp))
         Tpmin = min(Tpmin, pdata(np,prtp))
         Tpmax = max(Tpmax, pdata(np,prtp))
      end do
      !$acc end parallel
      !$acc wait

#ifdef MPI
      call mpi_allreduce(mpi_in_place,np_tmp_diag,1,mpi_integer8,mpi_sum,mpi_comm_world,ierr)

      droplet_diag0(1) = dble(tnumpart)
      droplet_diag0(2) = tnummult
      droplet_diag0(3) = tnumaerosol
      droplet_diag0(4) = tnumdrop
      droplet_diag0(5) = radavg
      droplet_diag0(6) = Tpavg
      droplet_diag0(7) = Tfavg
      droplet_diag0(8) = qfavg
      droplet_diag0(9) = prsavg
      droplet_diag0(10) = rhoavg
      droplet_diag0(11) = num_destroyed
      droplet_diag0(12) = mass_destroyed
      droplet_diag0(13) = eng_destroyed
      droplet_diag0(14) = m1_destroyed
      droplet_diag0(15) = m2_destroyed
      droplet_diag0(16) = num_injected
      droplet_diag0(17) = mass_injected
      droplet_diag0(18) = eng_injected
      droplet_diag0(19) = m1_injected
      droplet_diag0(20) = m2_injected
      droplet_diag0(21) = num100
      droplet_diag0(22) = num1000
      droplet_diag0(23) = tmasspart
      droplet_diag0(24) = mass_evap
      droplet_diag0(25) = mass_dpten
      droplet_diag0(26) = mass_reentry
      droplet_diag0(27) = eng_reentry
      droplet_diag0(28) = m1_reentry
      droplet_diag0(29) = m2_reentry
      droplet_diag0(30) = radmin
      droplet_diag0(31) = Tpmin
      droplet_diag0(32) = radmax
      droplet_diag0(33) = Tpmax

      ! The root rank will collect the diagnostic from different MPI ranks
      if ( myid == 0 ) then
         call mpi_reduce(MPI_IN_PLACE,droplet_diag0(1),num0-4,MPI_DOUBLE_PRECISION, &
                         MPI_SUM,0,MPI_COMM_WORLD,ierr)
      else
         call mpi_reduce(droplet_diag0(1),droplet_diag0(1),num0-4,MPI_DOUBLE_PRECISION, &
                         MPI_SUM,0,MPI_COMM_WORLD,ierr)
      end if
      if ( myid == 0 ) then
         call mpi_reduce(MPI_IN_PLACE,droplet_diag0(num0-3),2,MPI_DOUBLE_PRECISION, &
                         MPI_MIN,0,MPI_COMM_WORLD,ierr)
      else
         call mpi_reduce(droplet_diag0(num0-3),droplet_diag0(num0-3),2,MPI_DOUBLE_PRECISION, &
                         MPI_MIN,0,MPI_COMM_WORLD,ierr)
      end if
      if ( myid == 0 ) then
         call mpi_reduce(MPI_IN_PLACE,droplet_diag0(num0-1),2,MPI_DOUBLE_PRECISION, &
                         MPI_MAX,0,MPI_COMM_WORLD,ierr)
      else
         call mpi_reduce(droplet_diag0(num0-1),droplet_diag0(num0-1),2,MPI_DOUBLE_PRECISION, &
                         MPI_MAX,0,MPI_COMM_WORLD,ierr)
      end if
      if ( myid == 0 ) then 
         tnumpart = real(np_tmp_diag)
         tnummult = droplet_diag0(2)
         tnumaerosol = droplet_diag0(3)
         tnumdrop = droplet_diag0(4)
         radavg = droplet_diag0(5)
         Tpavg = droplet_diag0(6)
         Tfavg = droplet_diag0(7)
         qfavg = droplet_diag0(8)
         prsavg = droplet_diag0(9)
         rhoavg = droplet_diag0(10)
         num_destroyed = droplet_diag0(11)
         mass_destroyed = droplet_diag0(12)
         eng_destroyed = droplet_diag0(13)
         m1_destroyed = droplet_diag0(14)
         m2_destroyed = droplet_diag0(15)
         num_injected = droplet_diag0(16)
         mass_injected = droplet_diag0(17)
         eng_injected = droplet_diag0(18)
         m1_injected = droplet_diag0(19)
         m2_injected = droplet_diag0(20)
         num100 = droplet_diag0(21)
         num1000 = droplet_diag0(22)
         tmasspart = droplet_diag0(23)
         mass_evap = droplet_diag0(24)
         mass_dpten = droplet_diag0(25)
         mass_reentry = droplet_diag0(26)
         eng_reentry = droplet_diag0(27)
         m1_reentry = droplet_diag0(28)
         m2_reentry = droplet_diag0(29)
         radmin = droplet_diag0(30)
         Tpmin = droplet_diag0(31)
         radmax = droplet_diag0(32)
         Tpmax = droplet_diag0(33)
#endif
         if (tnumpart .gt. 0.0) then
            radavg = radavg/dble(tnumpart)
            radsqr = radsqr/dble(tnumpart)
            Tpavg = Tpavg/dble(tnumpart)
            Tpsqr = Tpsqr/dble(tnumpart)
            Tfavg = Tfavg/dble(tnumpart)
            qfavg = qfavg/dble(tnumpart)
            prsavg = prsavg/dble(tnumpart)
            rhoavg = rhoavg/dble(tnumpart)
         else 
            radavg = 0
            radsqr = 0
            Tpavg = 0
            Tpsqr = 0
            Tfavg = 0
            qfavg = 0
            prsavg = 0
            rhoavg = 0
         end if
#ifdef MPI
      end if
#endif



      !!!!!!! 1st order  !!!!!!!!

      !$acc parallel loop gang vector default(present)
      do iz=1,nk
         dumzh(iz) = zh(1,1,iz)
      enddo
      !$acc end parallel

      !$acc parallel loop gang vector default(present)
      do iz=kb,ke+1
         dumzf(iz) = zf(1,1,iz)
      enddo
      !$acc end parallel

      !$acc parallel loop gang vector default(present)
      do k = 1, nk
         partnum(k) = 0.0
         multnum(k) = 0.0
         partmass(k) = 0.0
         numconc(k) = 0.0
         massconc(k) = 0.0
         vp1mean(k) = 0.0
         vp2mean(k) = 0.0
         vp3mean(k) = 0.0
         vp1msqr(k) = 0.0
         vp2msqr(k) = 0.0
         vp3msqr(k) = 0.0
         uf1mean(k) = 0.0
         uf2mean(k) = 0.0
         uf3mean(k) = 0.0
         usgsmean(k) = 0.0
         vsgsmean(k) = 0.0
         wsgsmean(k) = 0.0
         sigm_smean(k) = 0.0
         m1src(k) = 0.0
         m2src(k) = 0.0
         m3src(k) = 0.0
         Tpsrc(k) = 0.0
         qvsrc(k) = 0.0
         rhovsrc(k) = 0.0
         Tf(k) = 0.0
         qf(k) = 0.0
         Tpmean(k) = 0.0
         Tpmsqr(k) = 0.0
         radmean(k) = 0.0
         radmsqrdp(k) = 0.0
         qfsat(k) = 0.0
         qstardp(k) = 0.0d0
         kmoist(k) = 0.0
         mse(k) = 0.0
         wk(k) = 0.0
         wtmp(k) = 0.0
      end do
      !$acc end parallel

      !! Number concentration

      !$acc parallel loop gang vector default(present)
      do np=1,nparcelsLocalActive
         if (pdata(np,prz).le.dumzf(kb)) then
            k = 1
         elseif (pdata(np,prz).ge.dumzf(ke+1)) then
            k = nk
         else
            kflag = 1
            k = undefined_index
            call find_vertical_location_index (k,pdata(np,prz),kb,ke+1,dumzf(:),kflag,.FALSE.)
            k = max(1,min(nk,k))
         endif
         !$acc atomic update
         partnum(k) = partnum(k) + 1.0
         !$acc atomic update
         multnum(k) = multnum(k) + pdata(np,prmult)
         !$acc atomic update
         partmass(k) = partmass(k) + (pdata(np,prms)+rhow*4.0/3.0*pi*pdata(np,prrp)**3)*pdata(np,prmult)
         !$acc atomic update
         vp1mean(k) = vp1mean(k) + pdata(np,prvpx)
         !$acc atomic update
         vp2mean(k) = vp2mean(k) + pdata(np,prvpy)
         !$acc atomic update
         vp3mean(k) = vp3mean(k) + pdata(np,prvpz)
         !$acc atomic update
         vp1msqr(k) = vp1msqr(k) + pdata(np,prvpx)**2
         !$acc atomic update
         vp2msqr(k) = vp2msqr(k) + pdata(np,prvpy)**2
         !$acc atomic update
         vp3msqr(k) = vp3msqr(k) + pdata(np,prvpz)**2
         !$acc atomic update
         uf1mean(k) = uf1mean(k) + pdata(np,pru)
         !$acc atomic update
         uf2mean(k) = uf2mean(k) + pdata(np,prv)
         !$acc atomic update
         uf3mean(k) = uf3mean(k) + pdata(np,prw)
         !$acc atomic update
         usgsmean(k) = usgsmean(k) + pdata(np,prusgs)
         !$acc atomic update
         vsgsmean(k) = vsgsmean(k) + pdata(np,prvsgs)
         !$acc atomic update
         wsgsmean(k) = wsgsmean(k) + pdata(np,prwsgs)
         !$acc atomic update
         sigm_smean(k) = sigm_smean(k) + pdata(np,prsigsgs)
         !$acc atomic update
         Tf(k) = Tf(k) + pdata(np,prt)
         !$acc atomic update
         qf(k) = qf(k) + pdata(np,prqv)
         !$acc atomic update
         Tpmean(k) = Tpmean(k) + pdata(np,prtp)
         !$acc atomic update
         Tpmsqr(k) = Tpmsqr(k) + pdata(np,prtp)**2
         !$acc atomic update
         radmean(k) = radmean(k) + pdata(np,prrp)
         !$acc atomic update
         radmsqrdp(k) = radmsqrdp(k) + dble(pdata(np,prrp))**2

         if (pdata(np,prt) .gt. 200.0) then    ! Avoid this breaking if the temperature is unrealistic 
                                               ! (like at initialization; other times this is a problem, but let it break elsewhere)
            call calc_qstar(qstar_tmp,pdata(np,prprs),pdata(np,prrho), &
                            pdata(np,prt),pdata(np,prqv),pdata(np,prtp), &
                            pdata(np,prms),pdata(np,prkap),pdata(np,prrp))
            !$acc atomic update
            qstardp(k) = qstardp(k) + qstar_tmp
            !$acc atomic update
            qfsat(k) = qfsat(k) + eslf(pdata(np,prprs),pdata(np,prt))*(mw/(ru*pdata(np,prt)*pdata(np,prrho)))
         else
            !$acc atomic write 
            qfsat(k) = 0.0
         end if
      end do
      !$acc end parallel

      !! Temperature source

      !$acc parallel default(present)
      !$acc loop gang
      do k=1,nk
         m1src_tmp = 0.0
         m2src_tmp = 0.0
         m3src_tmp = 0.0
         Tpsrc_tmp = 0.0
         qvsrc_tmp = 0.0
         rhovsrc_tmp = 0.0
         kmoist_tmp = 0.0
         mse_tmp = 0.0
         wk_tmp = 0.0
         winterp_tmp = 0.0
         !$acc loop vector collapse(2) reduction(+:Tpsrc_tmp,qvsrc_tmp,rhovsrc_tmp,m1src_tmp,m2src_tmp,m3src_tmp,kmoist_tmp,mse_tmp,wk_tmp,winterp_tmp)
         do j=1,nj
            do i=1,ni
               m1src_tmp = m1src_tmp + dpten(i,j,k,3)
               m2src_tmp = m2src_tmp + dpten(i,j,k,4)
               m3src_tmp = m3src_tmp + dpten(i,j,k,5)
               Tpsrc_tmp = Tpsrc_tmp + dpten(i,j,k,1)
               qvsrc_tmp = qvsrc_tmp + dpten(i,j,k,2)
               rhovsrc_tmp = rhovsrc_tmp + dpten(i,j,k,2)*rho(i,j,k)

               qt = qa(i,j,k,nqv)
               if( ptype.eq.7 .and. nqc.ge.1 ) qt = qt + qa(i,j,k,nqc)
               ta_tmp = (th0(i,j,k)+th_in(i,j,k))*(pi0(i,j,k)+ppa(i,j,k))
               lhv=lv1-lv2*ta_tmp
               kmoist_tmp = kmoist_tmp + ta_tmp*(cp + qt*cpl) + lhv*qa(i,j,k,nqv)
               mse_tmp = mse_tmp + ta_tmp*(cp + qt*cpl) + lhv*qa(i,j,k,nqv) + (1+qt)*g*dumzh(k)
               winterp_tmp = winterp_tmp + 0.5*(wa(i,j,k)+wa(i,j,k+1))
               wk_tmp = wk_tmp + (0.5*(wa(i,j,k)+wa(i,j,k+1)))*(ta_tmp*(cp + qt*cpl) + lhv*qa(i,j,k,nqv))
            end do
         end do
         m1src(k) = m1src_tmp/real(nx*ny)
         m2src(k) = m2src_tmp/real(nx*ny)
         m3src(k) = m3src_tmp/real(nx*ny)
         Tpsrc(k) = Tpsrc_tmp/real(nx*ny)
         qvsrc(k) = qvsrc_tmp/real(nx*ny)
         rhovsrc(k) = rhovsrc_tmp/real(nx*ny)
         kmoist(k) = kmoist_tmp/real(nx*ny)
         mse(k) = mse_tmp/real(nx*ny)
         wk(k) = wk_tmp/real(nx*ny)
         wtmp(k) = winterp_tmp/real(nx*ny)
      end do
      !$acc end parallel

      !Need these below for normalization
      if (stretch_x .eq. 0) then
         xl = dx*nx
      else
         xl = tot_x_len
      endif
      if (stretch_y .eq. 0) then
         yl = dy*nx
      else
         yl = tot_y_len
      endif

      !$acc update host (dumzf,dumzh,numconc,massconc,partnum,multnum,partmass,Tpsrc,qvsrc,rhovsrc,qf, &
      !$acc              Tf,radmean,Tpmean,qfsat,vp1mean,vp2mean, &
      !$acc              vp3mean,vp1msqr,vp2msqr,vp3msqr,radmsqrdp, &
      !$acc              uf1mean,uf2mean,uf3mean, &
      !$acc              usgsmean,vsgsmean,wsgsmean,sigm_smean, &
      !$acc              Tpmsqr,m1src,m2src,m3src,qstardp,kmoist,mse,wk,wtmp)

#ifdef MPI

      !Populate the reduction array:
      do iz=1,nk
         droplet_diag1(iz,1) = partnum(iz)
         droplet_diag1(iz,2) = vp1mean(iz)
         droplet_diag1(iz,3) = vp2mean(iz)
         droplet_diag1(iz,4) = vp3mean(iz)
         droplet_diag1(iz,5) = vp1msqr(iz)
         droplet_diag1(iz,6) = vp2msqr(iz)
         droplet_diag1(iz,7) = vp3msqr(iz)
         droplet_diag1(iz,8) = m1src(iz)
         droplet_diag1(iz,9) = m2src(iz)
         droplet_diag1(iz,10) = m3src(iz)
         droplet_diag1(iz,11) = Tpsrc(iz)
         droplet_diag1(iz,12) = qvsrc(iz)
         droplet_diag1(iz,13) = Tf(iz)
         droplet_diag1(iz,14) = qf(iz)
         droplet_diag1(iz,15) = Tpmean(iz)
         droplet_diag1(iz,16) = Tpmsqr(iz)
         droplet_diag1(iz,17) = radmean(iz)
         droplet_diag1(iz,18) = radmsqrdp(iz)
         droplet_diag1(iz,19) = qfsat(iz)
         droplet_diag1(iz,20) = qstardp(iz)
         droplet_diag1(iz,21) = partmass(iz)
         droplet_diag1(iz,22) = multnum(iz)
         droplet_diag1(iz,23) = uf1mean(iz)
         droplet_diag1(iz,24) = uf2mean(iz)
         droplet_diag1(iz,25) = uf3mean(iz)
         droplet_diag1(iz,26) = kmoist(iz)
         droplet_diag1(iz,27) = wk(iz)
         droplet_diag1(iz,28) = wtmp(iz)
         droplet_diag1(iz,29) = mse(iz)
         droplet_diag1(iz,30) = rhovsrc(iz)
         droplet_diag1(iz,31) = usgsmean(iz)
         droplet_diag1(iz,32) = vsgsmean(iz)
         droplet_diag1(iz,33) = wsgsmean(iz)
         droplet_diag1(iz,34) = sigm_smean(iz)
      end do

      ! The root rank will collect the diagnostic from different MPI ranks
      if ( myid == 0 ) then
         call mpi_reduce(MPI_IN_PLACE,droplet_diag1,nk*num1,MPI_DOUBLE_PRECISION, &
                         MPI_SUM,0,MPI_COMM_WORLD,ierr)
      else
         call mpi_reduce(droplet_diag1,droplet_diag1,nk*num1,MPI_DOUBLE_PRECISION, &
                         MPI_SUM,0,MPI_COMM_WORLD,ierr)
      end if


      if ( myid == 0 ) then 

         !Assign back to the arrays, now summed across MPI ranks
         do iz=1,nk
            partnum(iz) = droplet_diag1(iz,1)
            vp1mean(iz) = droplet_diag1(iz,2)
            vp2mean(iz) = droplet_diag1(iz,3)
            vp3mean(iz) = droplet_diag1(iz,4)
            vp1msqr(iz) = droplet_diag1(iz,5)
            vp2msqr(iz) = droplet_diag1(iz,6)
            vp3msqr(iz) = droplet_diag1(iz,7)
            m1src(iz) = droplet_diag1(iz,8)
            m2src(iz) = droplet_diag1(iz,9)
            m3src(iz) = droplet_diag1(iz,10)
            Tpsrc(iz) = droplet_diag1(iz,11)
            qvsrc(iz) = droplet_diag1(iz,12)
            Tf(iz) = droplet_diag1(iz,13)
            qf(iz) = droplet_diag1(iz,14)
            Tpmean(iz) = droplet_diag1(iz,15)
            Tpmsqr(iz) = droplet_diag1(iz,16)
            radmean(iz) = droplet_diag1(iz,17)
            radmsqrdp(iz) = droplet_diag1(iz,18)
            qfsat(iz) = droplet_diag1(iz,19)
            qstardp(iz) = droplet_diag1(iz,20)
            partmass(iz) = droplet_diag1(iz,21)
            multnum(iz) = droplet_diag1(iz,22)
            uf1mean(iz) = droplet_diag1(iz,23)
            uf2mean(iz) = droplet_diag1(iz,24)
            uf3mean(iz) = droplet_diag1(iz,25)
            kmoist(iz) = droplet_diag1(iz,26)
            wk(iz) = droplet_diag1(iz,27)
            wtmp(iz) = droplet_diag1(iz,28)
            mse(iz) = droplet_diag1(iz,29)
            rhovsrc(iz) = droplet_diag1(iz,30)
            usgsmean(iz) = droplet_diag1(iz,31)
            vsgsmean(iz) = droplet_diag1(iz,32)
            wsgsmean(iz) = droplet_diag1(iz,33)
            sigm_smean(iz) = droplet_diag1(iz,34)
         end do
 
#endif
         !These summed quantities need to be normalized
         !Either by the number of horizontal grid points or number of droplets (depends on quantity)
         do iz=1,nk
            dzf = dumzf(iz+1)-dumzf(iz)
            numconc(iz) = multnum(iz)/dzf/xl/yl
            sd_numconc(iz) = partnum(iz)/dzf/xl/yl
            massconc(iz) = partmass(iz)/dzf/xl/yl
            wk(iz) = wk(iz) - kmoist(iz)*wtmp(iz)  !So that it's fluctuations <w'k'>
            if (abs(partnum(iz)) .gt. 1.0e-10) then
               vp1mean(iz) = vp1mean(iz)/partnum(iz)
               vp2mean(iz) = vp2mean(iz)/partnum(iz)
               vp3mean(iz) = vp3mean(iz)/partnum(iz)
               vp1msqr(iz) = vp1msqr(iz)/partnum(iz)
               vp2msqr(iz) = vp2msqr(iz)/partnum(iz)
               vp3msqr(iz) = vp3msqr(iz)/partnum(iz)
               uf1mean(iz) = uf1mean(iz)/partnum(iz)
               uf2mean(iz) = uf2mean(iz)/partnum(iz)
               uf3mean(iz) = uf3mean(iz)/partnum(iz)
               usgsmean(iz) = usgsmean(iz)/partnum(iz)
               vsgsmean(iz) = vsgsmean(iz)/partnum(iz)
               wsgsmean(iz) = wsgsmean(iz)/partnum(iz)
               sigm_smean(iz) = sigm_smean(iz)/partnum(iz)
               Tf(iz) = Tf(iz)/partnum(iz)
               qf(iz) = qf(iz)/partnum(iz)
               Tpmean(iz) = Tpmean(iz)/partnum(iz)
               Tpmsqr(iz) = Tpmsqr(iz)/partnum(iz)
               radmean(iz) = radmean(iz)/partnum(iz)
               radmsqr(iz) = sngl( min( 1.0d30 , radmsqrdp(iz)/dble(partnum(iz)) ) )
               qfsat(iz) = qfsat(iz)/partnum(iz)
               ! GHB: i keep getting overflow errors here; so, just limit to a big number
               qstarmean(iz) = sngl( min( 1.0d30 , qstardp(iz)/dble(partnum(iz)) ) )
            else
               vp1mean(iz) = 0.0
               vp2mean(iz) = 0.0
               vp3mean(iz) = 0.0
               vp1msqr(iz) = 0.0
               vp2msqr(iz) = 0.0
               vp3msqr(iz) = 0.0
               uf1mean(iz) = 0.0
               uf2mean(iz) = 0.0
               uf3mean(iz) = 0.0
               usgsmean(iz) = 0.0
               vsgsmean(iz) = 0.0
               wsgsmean(iz) = 0.0
               sigm_smean(iz) = 0.0
               Tf(iz) = 0.0
               qf(iz) = 0.0
               Tpmean(iz) = 0.0
               Tpmsqr(iz) = 0.0
               radmean(iz) = 0.0
               radmsqr(iz) = 0.0
               qfsat(iz) = 0.0
               qstarmean(iz) = 0.0
            end if
         end do
#ifdef MPI
      end if
#endif

      !!!!!!! 2nd order  !!!!!!!!


      !$acc parallel loop gang vector collapse(2) default(present)
      do k = 1, nk
      do ir = 1,nbins
         partnumrz(k,ir) = 0.0
         multnumrz(k,ir) = 0.0
         vp3meanrz(k,ir) = 0.0
      end do
      end do
      !$acc end parallel

      !! Number concentration

      !$acc parallel loop gang vector default(present)
      do np=1,nparcelsLocalActive

         !First need its vertical location
         if (pdata(np,prz).le.dumzf(kb)) then
            k = 1
         elseif (pdata(np,prz).ge.dumzf(ke+1)) then
            k = nk
         else
            kflag = 1
            k = undefined_index
            call find_vertical_location_index (k,pdata(np,prz),kb,ke+1,dumzf(:),kflag,.FALSE.)
            k = max(1,min(nk,k))
         endif

         !Then need its radius location
         rad10_tmp = log10(pdata(np,prrp))
        
         !Figure out which bin it belongs to
         if (rad10_tmp .gt. rmax10 + 0.5*dhrad) then
            ibin = nbins
         elseif (rad10_tmp .lt. rmin10 - 0.5*dhrad) then
            ibin = 1
         else
            ibin = (floor((rad10_tmp-(rmin10-0.5*dhrad))/dhrad)+1)+1
         end if

         !$acc atomic update
         partnumrz(k,ibin) = partnumrz(k,ibin) + 1.0

         !$acc atomic update
         multnumrz(k,ibin) = multnumrz(k,ibin) + pdata(np,prmult)

         !$acc atomic update
         vp3meanrz(k,ibin) = vp3meanrz(k,ibin) + pdata(np,prvpz)

      end do


      !$acc update host (partnumrz,multnumrz,vp3meanrz)

#ifdef MPI
       !Sum up the histograms across MPI processes
       if (myid == 0) then
          call mpi_reduce(MPI_IN_PLACE,partnumrz,nk*nbins,MPI_REAL, &
                         MPI_SUM,0,MPI_COMM_WORLD,ierr)
          call mpi_reduce(MPI_IN_PLACE,multnumrz,nk*nbins,MPI_REAL, &
                         MPI_SUM,0,MPI_COMM_WORLD,ierr)
          call mpi_reduce(MPI_IN_PLACE,vp3meanrz,nk*nbins,MPI_REAL, &
                         MPI_SUM,0,MPI_COMM_WORLD,ierr)
       else
          call mpi_reduce(partnumrz,partnumrz,nk*nbins,MPI_REAL, &
                         MPI_SUM,0,MPI_COMM_WORLD,ierr)
          call mpi_reduce(multnumrz,multnumrz,nk*nbins,MPI_REAL, &
                         MPI_SUM,0,MPI_COMM_WORLD,ierr)
          call mpi_reduce(vp3meanrz,vp3meanrz,nk*nbins,MPI_REAL, &
                         MPI_SUM,0,MPI_COMM_WORLD,ierr)
       end if

      if ( myid == 0 ) then 
#endif
         !These summed quantities need to be normalized
         !Either by the number of horizontal grid points or number of droplets (depends on quantity)
         do iz=1,nk
         do ir=1,nbins
            dzf = dumzf(iz+1)-dumzf(iz)
            multnumrz(iz,ir) = multnumrz(iz,ir)/dzf/xl/yl
            if (abs(partnumrz(iz,ir)) .gt. 1.0e-10) then
               vp3meanrz(iz,ir) = vp3meanrz(iz,ir)/partnumrz(iz,ir)
            else
               vp3meanrz(iz,ir) = 0.0
            end if
         end do
         end do
#ifdef MPI
      end if
#endif




      !!!!!!! HISTOGRAMS  !!!!!!!!

      ! One last type of droplet stat is the histogram

      hist_radius = 0.0
      hist_dry_radius = 0.0
      hist_radius10 = 0.0
      tnumpart_r = 0.0

      !$acc update device (hist_radius,hist_dry_radius,hist_radius10)

      !$acc parallel loop gang vector default(present)
      do np=1,nparcelsLocalActive

         rad10_tmp = log10(pdata(np,prrp))
        
         !Figure out which bin it belongs to
         if (rad10_tmp .gt. rmax10 + 0.5*dhrad) then
            ibin = nbins
         elseif (rad10_tmp .lt. rmin10 - 0.5*dhrad) then
            ibin = 1
         else
            ibin = (floor((rad10_tmp-(rmin10-0.5*dhrad))/dhrad)+1)
         end if

         !Increment that bin by the multiplicity
         !(since that is how many droplets are said to have this size)
       
         !$acc atomic update
         hist_radius(ibin) = hist_radius(ibin) + pdata(np,prmult)

         if (pdata(np,prms) .gt. 0.0) then
            dry_rad10_tmp = log10((3.0*pdata(np,prms)/(4.0*pi*real(rho_solute)))**(1.0/3.0))
         else
            dry_rad10_tmp = rmin10 - 0.5*dhrad
         end if

         !Figure out which dry-radius bin it belongs to
         if (dry_rad10_tmp .gt. rmax10 + 0.5*dhrad) then
            ibin_dry = nbins
         elseif (dry_rad10_tmp .lt. rmin10 - 0.5*dhrad) then
            ibin_dry = 1
         else
            ibin_dry = (floor((dry_rad10_tmp-(rmin10-0.5*dhrad))/dhrad)+1)
         end if

         !$acc atomic update
         hist_dry_radius(ibin_dry) = hist_dry_radius(ibin_dry) + pdata(np,prmult)

         if (pdata(np,prz) .lt. 10.0) then
            !$acc atomic update
            hist_radius10(ibin) = hist_radius10(ibin) + pdata(np,prmult)
         end if

         !$acc atomic update
	 tnumpart_r(ibin) = tnumpart_r(ibin) + 1.0
     
      end do
      !$acc end parallel

      !$acc update host (hist_radius,hist_dry_radius,hist_radius10,hist_restime,hist_fallrad,tnumpart_r)

#ifdef MPI
       !Sum up the histograms across MPI processes
       if (myid == 0) then
          call mpi_reduce(MPI_IN_PLACE,hist_radius,nbins,MPI_REAL, &
                         MPI_SUM,0,MPI_COMM_WORLD,ierr)
          call mpi_reduce(MPI_IN_PLACE,hist_dry_radius,nbins,MPI_REAL, &
                         MPI_SUM,0,MPI_COMM_WORLD,ierr)
          call mpi_reduce(MPI_IN_PLACE,hist_radius10,nbins,MPI_REAL, &
                         MPI_SUM,0,MPI_COMM_WORLD,ierr)
          call mpi_reduce(MPI_IN_PLACE,hist_restime,nbins*nbins,MPI_REAL, &
                         MPI_SUM,0,MPI_COMM_WORLD,ierr)
          call mpi_reduce(MPI_IN_PLACE,hist_fallrad,nbins,MPI_REAL, &
                         MPI_SUM,0,MPI_COMM_WORLD,ierr)
          call mpi_reduce(MPI_IN_PLACE,tnumpart_r,nbins,MPI_REAL, &
                         MPI_SUM,0,MPI_COMM_WORLD,ierr)
       else
          call mpi_reduce(hist_radius,hist_radius,nbins,MPI_REAL, &
                         MPI_SUM,0,MPI_COMM_WORLD,ierr)
          call mpi_reduce(hist_dry_radius,hist_dry_radius,nbins,MPI_REAL, &
                         MPI_SUM,0,MPI_COMM_WORLD,ierr)
          call mpi_reduce(hist_radius10,hist_radius10,nbins,MPI_REAL, &
                         MPI_SUM,0,MPI_COMM_WORLD,ierr)
          call mpi_reduce(hist_restime,hist_restime,nbins*nbins,MPI_REAL, &
                         MPI_SUM,0,MPI_COMM_WORLD,ierr)
          call mpi_reduce(hist_fallrad,hist_fallrad,nbins,MPI_REAL, &
                         MPI_SUM,0,MPI_COMM_WORLD,ierr)
          call mpi_reduce(tnumpart_r,tnumpart_r,nbins,MPI_REAL, &
                         MPI_SUM,0,MPI_COMM_WORLD,ierr)
       end if
#endif

      fsmean = 0.0
      if (allocated(sfs_fs_profile)) then
         do iz=1,nk
            fsmean(iz) = 0.5*(sfs_fs_profile(iz)+sfs_fs_profile(iz+1))
         enddo
      endif

#ifdef NETCDF
      ! JS: this subroutine is not updated with the new MPI
      !     interface for the droplets yet
#ifdef MPI
      if ( myid == 0 ) then
#endif
      call writedropdiag_nc(nrec,nbins, &
           rtime,tnumpart,tnummult,tnumaerosol,tnumdrop,tmasspart,radavg,radsqr,radmin,radmax,Tpavg,Tpsqr,Tpmin,Tpmax,Tfavg,qfavg,prsavg,rhoavg, &
           dumzh,numconc,sd_numconc,massconc,vp1mean,vp2mean,vp3mean,uf1mean,uf2mean,uf3mean, &
           usgsmean,vsgsmean,wsgsmean,sigm_smean,fsmean, &
           vp1msqr,vp2msqr,vp3msqr,m1src,m2src,m3src,Tpsrc,qvsrc,rhovsrc,Tf,qf,Tpmean,Tpmsqr, &
           radmean,radmsqr,qfsat,qstarmean,kmoist,mse,wk,multnumrz,vp3meanrz,tnumpart_r)
#ifdef MPI
      end if
#endif
#endif
      !Now that it's done, remember to zero out the cumulative stats:
      hist_restime = 0.0
      hist_fallrad = 0.0
      num_destroyed = 0.0
      mass_destroyed = 0.0
      mass_evap = 0.0
      mass_dpten = 0.0
      mass_reentry = 0.0
      eng_reentry = 0.0
      m1_reentry = 0.0
      m2_reentry = 0.0
      eng_destroyed = 0.0
      m1_destroyed = 0.0
      m2_destroyed = 0.0
      num_injected = 0.0
      mass_injected = 0.0
      eng_injected = 0.0
      m1_injected = 0.0
      m2_injected = 0.0
      num100 = 0.0
      num1000 = 0.0
      

      !$acc update device (hist_restime,hist_fallrad,num_destroyed, &
      !$acc                mass_destroyed,mass_evap,mass_dpten,num_injected,mass_injected, &
      !$acc                eng_destroyed,m1_destroyed,m2_destroyed,eng_injected, &
      !$acc                mass_reentry,eng_reentry,m1_reentry,m2_reentry, &
      !$acc                m1_injected,m2_injected, &
      !$acc                num100,num1000)

      !$acc end data

      end subroutine droplet_diag

      subroutine write_drop_traj(nstep,mtime,pdata)
      use input, only : myid,nparcelsLocal,npvals,nparcelsLocalActive,prpidx,prprocidx,prx,pry,prz,prvpx,prvpy,prvpz,prrp,prtp,prms,prmult,prt,prqv
      implicit none

      integer, intent(in) :: nstep
      real, intent(in) :: mtime
      real, intent(in), dimension(nparcelsLocal,npvals) :: pdata
      integer, parameter :: num_local_traj = 500 !The maximum number of droplets which could be selected on a single MPI rank
      integer, parameter :: num_traj_skip = 1 !The stride of the droplet trajectory PIDX
      real :: compacted(num_local_traj,npvals)  !A buffer array to collect all droplets selected for trajectory output
      integer :: np,pcount,idx
      integer :: funit
      logical :: exist
      character*180 :: fname
      character*4 :: myid_char

      !$acc data create(compacted)

      !$acc update device(ngidx)
      
      !Pull out some subset of trajectories
      pcount = 0

      !$acc parallel loop gang vector default(present) private(idx)
      do np=1,nparcelsLocalActive

        !if ( transfer(pdata(np,prpidx),ngidx).eq.15 .and. transfer(pdata(np,prprocidx),ngidx).eq.1 ) then
        !   print *, 'DHR TRAJ:',pdata(np,prx),pdata(np,pry),pdata(np,prz),pdata(np,prrp)
        !end if


         if (mod(transfer(pdata(np,prpidx),ngidx),num_traj_skip).eq.0) then
           !$acc atomic capture
           pcount = pcount + 1
           idx = pcount
           !$acc end atomic

           if (idx.lt.num_local_traj) then
             compacted(idx,:) = pdata(np,:)
           else
             print *, 'WARNING: SELECTED TRAJECTORIES EXCEED MAXIMUM NUMBER'
           end if

         end if

      end do
      !$acc end parallel

      !$acc update host(compacted)
      
      !$acc end data

      !Now write them to a file
      funit = 17
      write(myid_char,'(i4.4)') myid
      fname = trim(adjustl("./particle_traj/"//myid_char//".dat"))

      if (nstep.eq.1) then  !If you are on the first time step of a run, just overwrite
         open(unit=funit,file=fname,access="stream",form="unformatted",status="replace")
      else
         inquire(file=fname,exist=exist)
         if (exist) then
            !File exists and you are NOT on first step, then append
            open(unit=funit,file=fname,access="stream",form="unformatted",status="old",position="append")
         else 
            !File doesn't exist, you're NOT on first step, but want to start trajectories
            open(unit=funit,file=fname,access="stream",form="unformatted",status="new")
          end if
      end if


      do np=1,pcount
        write(funit) real(transfer(compacted(np,prpidx),ngidx)),real(transfer(compacted(np,prprocidx),ngidx)),mtime,compacted(np,prx),compacted(np,pry),compacted(np,prz),compacted(np,prvpx),compacted(np,prvpy),compacted(np,prvpz),compacted(np,prrp),compacted(np,prtp),compacted(np,prms),compacted(np,prmult),compacted(np,prt),compacted(np,prqv)
      end do
      
      close(funit)



      end subroutine write_drop_traj

      subroutine find_horizontal_location_index (loc_ind, loc, lb, ub, dsize, end_ind, ind)
      !$acc routine seq

      use constants, only : undefined_index

      implicit none

      integer,                      intent(inout) :: loc_ind    ! x/y location index of a parcel
      real,                         intent(in)    :: loc        ! current x/y location of a parcel
      integer,                      intent(in)    :: lb, ub     ! lower and upper bounds of dsize
      real, dimension(lb:ub),       intent(in)    :: dsize      ! range of x/y dimension
      integer,                      intent(in)    :: end_ind    ! end index of x/y dimension
      integer,                      intent(inout) :: ind        ! return the x/y location index closest to 
                                                                ! the current parcel location
      ! local variable
      integer :: i
      ! Sanity check:
      ! - If input x/y location is outside the x/y range, return directly
      if ( loc .lt. dsize(lb) .or. loc .gt. dsize(end_ind) ) return

      if ( loc_ind .ne. undefined_index ) then
         i = min (end_ind, loc_ind + location_offset)
         do while( ind .lt. 0 .and. i .gt. loc_ind - location_offset - 1 )
            i = i - 1
            if ( loc .ge. dsize(i) .and. loc .le. dsize(i+1) ) then
               ind = i
               loc_ind = ind
            end if
         end do
         ! Sanity check: 
         ! - If a parcel moves too far and outside search range, 
         !      this scheme would fail;
         ! - Switch back to the original linear search scheme 
         if ( ind .lt. 0 ) then
            i = end_ind
            do while( ind .lt. 0 .and. i .gt. 1 )
               i = i - 1
               if ( loc .ge. dsize(i) .and. loc .le. dsize(i+1) ) then
                  ind = i
                  loc_ind = ind
               end if
            end do
         end if
      else ! Always search from the end when:
           !    - it is the first time step
           !    - a parcel enters a new or different MPI process
         i = end_ind
         do while( ind .lt. 0 .and. i .gt. 1 )
            i = i - 1
            if ( loc .ge. dsize(i) .and. loc .le. dsize(i+1) ) then
               ind = i
               loc_ind = ind
            end if
         end do
      end if

      end subroutine find_horizontal_location_index

      subroutine find_vertical_location_index (loc_ind, loc, lb, ub, dsize, ind, is_ge)
      !$acc routine seq

      use constants, only : undefined_index 

      implicit none

      integer,                      intent(inout) :: loc_ind    ! z location index of a parcel
      real,                         intent(in)    :: loc        ! current z location of a parcel
      integer,                      intent(in)    :: lb, ub     ! lower and upper bounds of dsize
      real, dimension(lb:ub),       intent(in)    :: dsize      ! range of z dimension
      integer,                      intent(inout) :: ind        ! return the z location index closest
                                                                ! to the current parcel location
      logical,                      intent(in)    :: is_ge      ! TRUE if use "ge"; FALSE if use "gt"

      ! Local variable
      integer :: i
      ! Sanity check:
      ! - If input z location is outside the z range, return directly

      if ( loc .lt. dsize(lb) .or. loc .gt. dsize(ub) ) return

      if ( loc_ind .ne. undefined_index ) then 
         i = max (ind, loc_ind - location_offset - 1)
         ! Sanity check: 
         ! - If a parcel falls too low and outside search range,
         !      this scheme would fail;
         ! - Reset the lower bound in this case
         if ( loc .lt. dsize(i) ) then
            i = ind
         end if
         if ( is_ge ) then
            do while( loc .ge. dsize(i+1) )
               i = i + 1
            end do
         else
            do while( loc .gt. dsize(i+1) )
               i = i + 1
            end do
         end if
         ind = i
      else ! Always search from the end when:
           !    - it is the first time step
           !    - a parcel enters a new or different MPI process
         if ( is_ge ) then
            do while ( loc .ge. dsize(ind+1) )
               ind = ind + 1
            end do
         else
            do while ( loc .gt. dsize(ind+1) )
               ind = ind + 1
            end do
         end if
      end if
      loc_ind = ind 

      end subroutine find_vertical_location_index

      subroutine rad_solver2(guess,mflag,prsval,rhoval,tval,qval,Tp,m_s,kappa_p,radius,np)
      !$acc routine seq
      use input , only : pi_dp
      use constants , only : mw,ru,rho_solute
      use cm1libs , only : deslf
      implicit none

      double precision, intent(out) :: guess
      integer, intent(out) :: mflag
      real, intent(in) :: prsval,rhoval,tval,qval,Tp,m_s,kappa_p,radius
      integer, intent(in) :: np
      double precision :: dry_radius3, esa, rhval

      mflag = 0
      esa = deslf(dble(prsval),dble(tval))  !Saturation vapor pressure at droplet temperature

      rhval = (ru*tval*rhoval*qval)/(mw*esa)

      !Calculate the equilibrium radius based on "rhval"
      !Solve the cubic for the equilibrium radius

      if (rhval .lt. 0.999d0) then
         dry_radius3 = dble(m_s)/(rho_solute*((4.0d0/3.0d0)*pi_dp))
         guess = kohler_equil_radius_dry3(dry_radius3,dble(kappa_p),  &
                                          dble(tval),rhval)
      else 

        guess = radius
        mflag = 1
      end if

      end subroutine rad_solver2

      subroutine gauss_newton_2d(diffnorm,dt_nondim,taup_scale,rt_start, &
                                 rt_zeros,flag,prsval,rhoval,tval,qval, &
                                 Tp,m_s,kappa_p,radius,np)
        !$acc routine seq

        implicit none

        double precision, intent(in) :: diffnorm,dt_nondim,taup_scale,rt_start(2)
        double precision, intent(in) :: prsval,rhoval,tval,qval,Tp,m_s,kappa_p,radius
        double precision, intent(out) :: rt_zeros(2)
        integer, intent(out) :: flag
        integer, intent(in) :: np

        double precision :: error,fv1(2),fv2(2),v1(2),rel,det
        double precision :: relax, coeff
        double precision, dimension(1:2, 1:2) :: J,fancy,inv,finalJ
        integer :: iterations,neg,counts,iteration_max

        double precision :: correct(2)

        iterations = 0
        flag = 0
        error = 1.0d-8

        !Initialize the solution vector
        v1(1) = rt_start(1)
        v1(2) = rt_start(2)
         
        !Initialize the correction to zero
        correct(1) = 0.0d0
        correct(2) = 0.0d0

        !Default max iterations before Gauss-Newton deemed failure (and moves onto a new scheme)
        !Rare that it gets above ~5
        iteration_max = 50

        do while (iterations<iteration_max)

                iterations = iterations + 1

                !Compute the RHS of the droplet temp and radius equations
                call ie_vrt_nd(diffnorm,v1(1),v1(2),fv1,dt_nondim, &
                               taup_scale,prsval,rhoval,tval,qval, &
                               Tp,m_s,kappa_p,radius,np,flag)
                !Approximate the Jacobian
                call jacob_approx_2d(diffnorm,v1(1),v1(2),dt_nondim,J, &
                                     taup_scale,prsval,rhoval,tval,qval, &
                                     Tp,m_s,kappa_p,radius,np,flag)

              if( abs(J(1,1)).gt.1.0d76 ) flag = 1
              if( abs(J(1,2)).gt.1.0d76 ) flag = 1
              if( abs(J(2,1)).gt.1.0d76 ) flag = 1
              if( abs(J(2,2)).gt.1.0d76 ) flag = 1

              if( flag.eq.0 )then
                !Matrix to be inverted via G-N method
                fancy(1,1) = J(1,1)*J(1,1)+J(2,1)*J(2,1)
                fancy(1,2) = J(1,1)*J(1,2)+J(2,1)*J(2,2)
                fancy(2,1) = J(1,2)*J(1,1)+J(2,2)*J(2,1)
                fancy(2,2) = J(1,2)*J(1,2)+J(2,2)*J(2,2)

                !Determinant -- exit if it is too near zero, indicates failed convergence
                det = fancy(1,1)*fancy(2,2) - fancy(1,2)*fancy(2,1)
                ! GHB: try this
                if (  (abs(det) .lt. 1.0d-10) .or. (abs(det).gt.1.0d100) ) then
                   flag = 1
                   EXIT
                end if
              else
                exit
              endif
                
                call inverse_finder_2d(fancy,det,inv)

                finalJ(1,1) = inv(1,1)*J(1,1)+inv(1,2)*J(1,2)
                finalJ(1,2) = inv(1,1)*J(2,1)+inv(1,2)*J(2,2)
                finalJ(2,1) = inv(2,1)*J(1,1)+inv(2,2)*J(1,2)
                finalJ(2,2) = inv(2,1)*J(2,1)+inv(2,2)*J(2,2)

                !How much to correct the solution vector
                correct(1) = finalJ(1,1)*fv1(1)+finalJ(1,2)*fv1(2)
                correct(2) = finalJ(2,1)*fv1(1)+finalJ(2,2)*fv1(2)

                !Update the solution vector
                rt_zeros(1) = v1(1) - correct(1)
                rt_zeros(2) = v1(2) - correct(2)

                relax = 1.0d0
                counts = 0
                !If either the temperature or radius goes negative, take a series of smaller adjustment steps
                do while ((rt_zeros(1)<0.0d0) .OR. (rt_zeros(2)<0.0d0) .OR. (rt_zeros(1) .ne. rt_zeros(1)))

                   counts = counts + 1
                   coeff = 0.5d0
                   relax = relax * coeff
                   rt_zeros(1) = v1(1)-(finalJ(1,1)*fv1(1)+finalJ(1,2)*fv1(2))*relax
                   rt_zeros(2) = v1(2)-(finalJ(2,1)*fv1(1)+finalJ(2,2)*fv1(2))*relax

                   if (counts>10) EXIT
                end do

                !Failure to converge if these drop too low -- send to LV solver
                if (rt_zeros(1)<0.01d0 .OR. rt_zeros(2)<0.01d0) then
                   flag = 1
                   EXIT
                end if

                !Converged when the correction is small
                if (sqrt(correct(1)*correct(1)+correct(2)*correct(2))<error) then
                   EXIT
                end if

                v1(1) = rt_zeros(1)
                v1(2) = rt_zeros(2)

        end do
      !These indicate that this failed -- set flag = 1 to send to LV solver
      if (iterations == iteration_max) flag = 1
      if ((rt_zeros(1) .ne. rt_zeros(1)) .OR. rt_zeros(1)<0.0d0 .OR. (rt_zeros(2) .ne. rt_zeros(2)) .OR. rt_zeros(2)<0.0d0) flag = 1

      end subroutine gauss_newton_2d

      subroutine LV_solver(diffnorm,dt_nondim,taup_scale,rt_start, &
                           rt_zeros,flag,prsval,rhoval,tval,qval, &
                           Tp,m_s,kappa_p,radius,np)
        !$acc routine seq
        implicit none

        double precision, intent(in) :: diffnorm,dt_nondim,taup_scale,rt_start(2)
        double precision, intent(in) :: prsval,rhoval,tval,qval,Tp,m_s,kappa_p,radius
        double precision, intent(out) :: rt_zeros(2)
        integer, intent(out) :: flag
        integer, intent(in) :: np

        double precision :: error,fv1(2),fv2(2),v1(2),rel,det
        double precision :: diff,lambda,lup,ldown
        double precision :: C(2),newC(2),gradC(2),correct(2)
        double precision, dimension(1:2, 1:2) :: J,I,g,invg
        integer :: iterations,neg,iterations_max


        !Performs the Levenberg-Marquardt algorithm -- a modification on Newton's method

        error = 1.0d-8

        
        !Preliminary
        I(1,1)=1.0d0
        I(2,1)=0.0d0
        I(1,2)=0.0d0
        I(2,2)=1.0d0
        iterations = 0
        iterations_max = 1000
        flag = 0
        v1(1) = rt_start(1)
        v1(2) = rt_start(2)
        fv2(1) = 1.0d0
        fv2(2) = 1.0d0

        !These are parameters to the solver, could be adjusted but these work
        lambda = 0.001d0
        lup = 2.0d0
        ldown = 2.0d0

        do while ((sqrt(fv2(1)*fv2(1)+fv2(2)*fv2(2)) > error) .AND. (iterations<iterations_max))

        iterations = iterations + 1

        !Approximate the Jacobian of the system
        call jacob_approx_2d(diffnorm,v1(1),v1(2),dt_nondim,J, &
                             taup_scale,prsval,rhoval,tval,qval, &
                             Tp,m_s,kappa_p,radius,np,flag)
        !Compute the RHS of the temperature and radius equations
        call ie_vrt_nd(diffnorm,v1(1),v1(2),fv1,dt_nondim,taup_scale, &
                       prsval,rhoval,tval,qval,Tp,m_s,kappa_p, &
                       radius,np,flag)

      if( abs(J(1,1)).gt.1.0d76 ) flag = 1
      if( abs(J(1,2)).gt.1.0d76 ) flag = 1
      if( abs(J(2,1)).gt.1.0d76 ) flag = 1
      if( abs(J(2,2)).gt.1.0d76 ) flag = 1

      if( flag.eq.0 )then
        !Calculate the update matrix which must be inverted
        g(1,1) = J(1,1)*J(1,1)+J(2,1)*J(2,1)+lambda*I(1,1)
        g(1,2) = J(1,1)*J(1,2)+J(2,1)*J(2,2)+lambda*I(1,2)
        g(2,1) = J(1,2)*J(1,1)+J(2,2)*J(2,1)+lambda*I(2,1)
        g(2,2) = J(1,2)*J(1,2)+J(2,2)*J(2,2)+lambda*I(2,2)

        gradC(1) = J(1,1)*fv1(1)+J(2,1)*fv1(2)
        gradC(2) = J(1,2)*fv1(1)+J(2,2)*fv1(2)

        C(1) = 0.5d0*fv1(1)*fv1(1)
        C(2) = 0.5d0*fv1(2)*fv1(2)

        !Exit if the determinant is too close to zero -- failed convergence
        det = g(1,1)*g(2,2) - g(1,2)*g(2,1)
        ! GHB: try this
        if ( (abs(det) .lt. 1.0d-10) .or. (abs(det).gt.1.0d100) ) then
             flag = 1
             EXIT
        end if
        call inverse_finder_2d(g,det,invg)
      else
        EXIT
      endif

        !Solve for correction vector
        correct(1) = invg(1,1)*gradC(1)+invg(1,2)*gradC(2)
        correct(2) = invg(2,1)*gradC(1)+invg(2,2)*gradC(2)

        rt_zeros(1) = v1(1) - correct(1)
        rt_zeros(2) = v1(2) - correct(2)

        !Successful convergence if correction is small
        if (sqrt(correct(1)*correct(1)+correct(2)*correct(2)) < error) then
           EXIT
        end if

        !Failed if temperature or radius goes negative
        if (rt_zeros(1)<0.0d0 .OR. rt_zeros(2)<0.0d0) then
            flag = 1
            EXIT
        end if

        !Use the RHS to update the lambda parameter
        call ie_vrt_nd(diffnorm,rt_zeros(1),rt_zeros(2),fv2,dt_nondim, &
                       taup_scale,prsval,rhoval,tval,qval,Tp,m_s, &
                       kappa_p,radius,np,flag)

      if( abs(fv1(1)).gt.1.0d76 ) flag = 1
      if( abs(fv1(2)).gt.1.0d76 ) flag = 1
      if( abs(fv2(1)).gt.1.0d76 ) flag = 1
      if( abs(fv2(2)).gt.1.0d76 ) flag = 1

      if( flag.eq.0 )then
        newC(1) = 0.5d0*fv2(1)*fv2(1)
        newC(2) = 0.5d0*fv2(2)*fv2(2)

        if (sqrt(newC(1)*newC(1)+newC(2)*newC(2))<sqrt(C(1)*C(1)+C(2)*C(2))) then
           v1(1) = rt_zeros(1)
           v1(2) = rt_zeros(2)
           lambda = lambda/ldown
        else
           lambda = lambda*lup
        end if
      else
        EXIT
      endif

        end do

        !Failed if iterations hits maximum
        if (iterations==iterations_max) then
           flag = 1
        end if

        !Failed if it returns negative radius or temperature
        if (rt_zeros(1) < 0.0d0 .OR. rt_zeros(2) < 0.0d0) then
           flag = 1
        end if

      end subroutine LV_solver

      subroutine inverse_finder_2d(C,det,invC)
        !$acc routine seq
        implicit none
        double precision, intent(in) :: det
        double precision, dimension(1:2, 1:2), intent(in) :: C
        double precision, dimension(1:2, 1:2), intent(out) :: invC

        invC = reshape((/C(2, 2), -C(2,1), -C(1, 2), C(1, 1)/),(/2,2/))
        invC = (1.0d0/det)*invC

      end subroutine inverse_finder_2d

      subroutine jacob_approx_2d(diffnorm,rnext,tnext,dt_nondim,J, &
                                 taup_scale,prsval,rhoval,tval,qval, &
                                 Tp,m_s,kappa_p,radius,np,flag)
        !$acc routine seq
        implicit none
        integer :: n

        double precision, intent(in) :: diffnorm,rnext,tnext,dt_nondim,taup_scale,prsval,rhoval,tval,qval,Tp,m_s,kappa_p,radius
        double precision, intent(out), dimension(1:2, 1:2) :: J
        double precision :: diff,v_output(3),rt_output(2),xper(2),fxper(2),ynext(2),xper2(2),fxper2(2)
        integer, intent(in) :: np
        integer, intent(inout) :: flag

        !Take a very small difference to approximate the derivatives
        diff = 1d-12

        ynext(1) = rnext
        ynext(2) = tnext

        !Evaluate RHS 
        call ie_vrt_nd(diffnorm,rnext,tnext,rt_output,dt_nondim, &
                       taup_scale,prsval,rhoval,tval,qval,Tp,m_s, &
                       kappa_p,radius,np,flag)

        xper(1) = ynext(1)
        xper(2) = ynext(2)
        xper2(1) = ynext(1)
        xper2(2) = ynext(2)

        !Now evaluate RHS a bit ahead and behind the base point
        do n=1, 2
           xper(n) = xper(n) + diff
           xper2(n) = xper2(n) - diff

           call ie_vrt_nd(diffnorm,xper(1),xper(2),fxper,dt_nondim, &
                          taup_scale,prsval,rhoval,tval,qval,Tp,m_s, &
                          kappa_p,radius,np,flag)
           call ie_vrt_nd(diffnorm,xper2(1),xper2(2),fxper2,dt_nondim, &
                          taup_scale,prsval,rhoval,tval,qval,Tp,m_s, &
                          kappa_p,radius,np,flag)

           !Use these differences to compute the Jacobian
           J(1,n) = (fxper(1)-rt_output(1))/diff
           J(2,n) = (fxper(2)-rt_output(2))/diff
           xper(n) = ynext(n)
           xper2(n) = ynext(n)
        end do

      end subroutine jacob_approx_2d

      subroutine ie_vrt_nd(diffnorm,tempr,tempt,rt_output,dt_nondim, &
                           taup_scale,prsval,rhoval,tval,qval,Tp,m_s, &
                           kappa_p,radius,np,flag)
      !$acc routine seq
      use constants, only : rhow_dp,mw,ru,surften,rho_solute, &
                            cp_dp,cpl_dp,lv1_dp,lv2_dp
      use input, only : viscosity,pr_num,sc_num,pi_dp
      use cm1libs , only : drslf,deslf
      implicit none

      double precision, intent(in) :: diffnorm,tempr,tempt,taup_scale,dt_nondim,prsval,rhoval,tval,qval,Tp,m_s,kappa_p,radius
      double precision, intent(out) :: rT_output(2)
      integer, intent(in) :: np
      integer, intent(inout) :: flag

      double precision :: esa,dnext,rhop,Rep,taup,rprime,Tprime,qstr,Shp,Nup,VolP,lhv,qstr_test
      double precision :: Tnext,rnext
      double precision :: tmp

        ! quantities come in already non-dimensionalized, so must be converted back;
        rnext = tempr*radius
        Tnext = tempt*Tp
        Tnext = max(Tnext,1.0d-12) !To avoid divide by zero if the solution starts to diverge; gets flagged later
        dnext = rnext*2.0d0

        esa = deslf(prsval,tval)
        VolP = (4.0d0/3.0d0)*pi_dp*rnext**3
        rhop = (m_s + VolP*rhow_dp)/VolP

        Rep = max( 0.0d0 , dnext*diffnorm/dble(viscosity) )
        taup = (rhop*dnext**2)/(18.0d0*rhoval*dble(viscosity))
        Nup = 2.0d0 + 0.6d0*dsqrt(Rep)*dble(pr_num)**(1.0d0/3.0d0)
        Shp = 2.0d0 + 0.6d0*dsqrt(Rep)*dble(sc_num)**(1.0d0/3.0d0)

        lhv=lv1_dp-lv2_dp*tval

        !!! Humidity !!!
        ! GHB prevent overflow by limiting term inside exponent:
        tmp = ((lhv*mw/ru)*((1.0d0/max(1.0d-10,tval))- &
              (1.0d0/max(1.0d-10,Tnext)))) + &
              ((2.0d0*mw*surften)/(ru*rhow_dp*rnext*Tnext)) - &
              ((kappa_p*m_s*rhow_dp/rho_solute)/(VolP*rhop-m_s))
        if( tmp.gt.600.0 )then
          qstr = qval
          flag = 1
        else
          qstr = (mw/(ru*Tnext*rhoval))*esa*dexp( tmp )
          qstr_test = drslf(dble(prsval),dble(tval))*dexp( tmp )
        endif

        !!!!!!!!!!!!!!!!!!

        !!! Radius !!!
        rprime = (1.0d0/9.0d0)*(Shp/dble(sc_num))*(rhop/rhow_dp)*(rnext/taup)*(qval - qstr)
        rprime = rprime*(taup_scale/radius)

        !!! Temperature !!!
        Tprime = -(1.0d0/3.0d0)*(Nup/dble(pr_num))*(cp_dp/cpl_dp)*(rhop/rhow_dp)/taup*(Tnext-tval) + 3.0d0*lhv/(rnext*cpl_dp)*rprime*(radius/taup_scale)
        Tprime = Tprime*(taup_scale/Tp)

        rT_output(1) = rnext/radius - 1.0d0  - dt_nondim*rprime
        rT_output(2) = Tnext/Tp - 1.0d0  - dt_nondim*Tprime

      end subroutine ie_vrt_nd

      subroutine calc_qstar(qstar,prsval,rhoval,tval,qval,Tp,m_s,kappa_p,radius)
      !$acc routine seq
      use constants , only : rhow_dp,mw,surften,ru,rho_solute,lv1_dp,lv2_dp
      use input, only : viscosity,pr_num,sc_num,pi_dp
      use cm1libs , only : deslf,drslf
      implicit none

      real, intent(in) :: prsval,rhoval,tval,qval,Tp,m_s,kappa_p,radius
      double precision, intent(out) :: qstar

      double precision :: esa,Rep,taup,rprime,Tprime,qstr,Shp,Nup,lhv
      double precision :: diameter
      double precision :: Volp,rhop

      !Calculate qstar, the specific humidity at the droplet surface 
   
      diameter = dble(radius)*2.0d0

      esa = deslf(dble(prsval),dble(tval))
      VolP = (4.0d0/3.0d0)*pi_dp*dble(radius)**3
      rhop = (dble(m_s) + VolP*rhow_dp)/VolP

      lhv=lv1_dp-lv2_dp*dble(tval)

      ! GHB prevent overflow by limiting term inside exponent:
      qstar = (mw/(ru*dble(Tp)*dble(rhoval)))*esa*dexp( min( 600.0d0 , ((lhv*mw/ru)*((1.0d0/dble(tval))-(1.0d0/dble(Tp)))) + &
              ((2.0d0*mw*surften)/(ru*rhow_dp*dble(radius)*dble(Tp))) - &
              ((dble(kappa_p)*dble(m_s)*rhow_dp/rho_solute)/(VolP*rhop-dble(m_s))) ) )

      end subroutine calc_qstar

      function kohler_equil_radius(dry_radius,kappa_p,temp_p,rh) result(radius)
      !$acc routine seq

      implicit none

      double precision, intent(in) :: dry_radius,kappa_p,temp_p,rh
      double precision :: radius

      radius = kohler_equil_radius_dry3(dry_radius**3,kappa_p,temp_p,rh)

      end function kohler_equil_radius

      subroutine lognormal_droplet(rad_init,m_s,kappa_p,randomNumbers)
      !$acc routine seq
      use constants, only : rho_solute,pi
      use MersenneTwister_mod

      implicit none

      real, intent(out) :: rad_init,m_s
      real, intent(in) :: kappa_p
      type(randomNumberSequence), intent(inout) :: randomNumbers

      double precision, parameter :: lognorm_m = -1.7570d0
      double precision, parameter :: lognorm_s =  0.3500d0
      double precision, parameter :: init_rh = 0.80d0
      double precision, parameter :: init_temp = 290.0d0
      double precision :: rand_dp,rand2_dp,normal_sample
      double precision :: dry_diameter_um,dry_radius,wet_radius

      rand_dp = max(getRandomReal(randomNumbers),1.0d-12)
      rand2_dp = getRandomReal(randomNumbers)
      normal_sample = sqrt(-2.0d0*log(rand_dp))  &
                      *cos(2.0d0*dble(pi)*rand2_dp)

      dry_diameter_um = exp(lognorm_m+lognorm_s*normal_sample)
      dry_radius = 0.5d0*dry_diameter_um*1.0d-6
      wet_radius = kohler_equil_radius(dry_radius,dble(kappa_p),  &
                                       init_temp,init_rh)

      rad_init = real(wet_radius)
      m_s = real(rho_solute*4.0d0/3.0d0*dble(pi)*dry_radius**3)

      end subroutine lognormal_droplet

      function kohler_equil_radius_dry3(dry_radius3,kappa_p,temp_p,rh) result(radius)
      !$acc routine seq
      use input, only : pi_dp
      use constants, only : mw,surften,ru,rhow_dp

      implicit none

      double precision, intent(in) :: dry_radius3,kappa_p,temp_p,rh
      double precision :: radius
      double precision :: a,c,Q,R,M,theta,S,T

      a = -(2.0d0*mw*surften)/(ru*rhow_dp*temp_p)/LOG(rh)
      c = kappa_p*dry_radius3/LOG(rh)

      !Use Cardano's method for cubic solution
      Q = (a*a)/9.0d0
      R = (2.0d0*a*a*a+27.0d0*c)/54.0d0
      M = R*R-Q*Q*Q

      if (M<0.0d0) then
        theta = acos(R/sqrt(Q*Q*Q))
        radius = -(2.0d0*sqrt(Q)*cos((theta-pi_dp*2.0d0)/3.0d0))  &
                 -a/3.0d0

        if (radius < 0.0d0) then
          radius = -(2.0d0*sqrt(Q)*cos((theta+pi_dp*2.0d0)/3.0d0))  &
                   -a/3.0d0
        end if

      else
        S = -(R/abs(R))*(abs(R)+sqrt(M))**(1.0d0/3.0d0)
        T = Q/S
        radius = S + T - a/3.0d0
      end if

      end function kohler_equil_radius_dry3

      function crit_radius(m_s,kappa_p,Tf)
      !$acc routine seq
      use constants
      use input
      use mpi
      implicit none

      integer :: i,maxidx
      integer, parameter :: N=1000
      real, intent(in) :: m_s,kappa_p,Tf
      double precision :: Volp,rhop
      real :: radval(N)
      double precision :: SS(N)
      real :: radstart,radend,dr
      real :: crit_radius

      radstart = -8
      radend = -3
      dr = (radstart-radend)/N
      maxidx = 1

      !$acc loop seq
      do i=1,N
        radval(i) = 10**(radstart - (i-1)*dr)
        Volp = (4.0/3.0)*pi*radval(i)**3
        rhop = (m_s + Volp*rhow)/Volp
        SS(i) = exp((2.0*mw*surften)/(ru*rhow*radval(i)*Tf) - (kappa_p*m_s*rhow/rho_solute)/(Volp*rhop-m_s))
        if (i > 1) then
           if (SS(i) > SS(maxidx)) then
              maxidx = i 
           end if
        end if
      end do
      crit_radius = radval(maxidx)

      end function crit_radius     

      subroutine droplet_injection(pdata,xf,yf,time_since_inject,mtime,my_reintro)
      !Inject new particles according to some rule
      !Here use the sea spray generation function (SSGF) of Andreas (1998)
      use input, only : nparcelsLocal,npvals,myid,ni,nj,ib,ie,jb,je, &
                        prx,pry,prz,pru,prv,prw,prvpx,prvpy,prvpz, &
                        prusgs,prvsgs,prwsgs,prsigsgs, &
                        prrp,prrp0,prtp,prms,prkap,pract,prtime, &
                        prmult,prt,prrho,prprs,prqv,prpidx,prprocidx,nparcelsLocalActive,numprocs,nparcelsMax, &
                        time_phys_H2D,time_phys_D2H,time_droplet,timestats,mytime, &
                        drop_mult,tsk0,pi_sp,myid,nx,ny,dx,dy
      use constants
      use MersenneTwister_mod
#ifdef MPI
      use mpi
#endif

      real, intent(inout), dimension(nparcelsLocal,npvals) :: pdata
      real, intent(in), dimension(ib:ie+1) :: xf
      real, intent(in), dimension(jb:je+1) :: yf
      real, intent(in) :: time_since_inject
      double precision, intent(in) :: mtime
      integer, intent(out) :: my_reintro
    
      integer, parameter :: nbin = 100
      integer :: i,np,idx_tmp
      integer(i8) :: tot_after_reintro,total_reintro
      integer :: sum_buf(2)
      double precision :: dFssum(nbin+1)  !Discretized cumulative spray generation function (to be calculated)
      double precision :: binsdata(nbin),binsdata10(nbin)  !Discretized bins for SSGF; "10" is for the log10 value
      double precision :: binsdata_edge(nbin+1),binsdata10_edge(nbin+1) !Bin edges

      double precision :: totdrops  !Total number being produced during this call to droplet_injection
      double precision :: rad_init  !Initial radius, being calculated one at a time according to SSGF
      real :: u10
      type(randomNumberSequence) :: randomNumbers

      real :: xrange,yrange,zrange
      real :: salinity
      real :: my_reintro_tmp  !A temporaray variable to store a real version of my_reintro
      
      !implementing the Andreas 1998 sea spray generation function
      !Set the parameters of the two lognormals:
      double precision :: c1,c2,c3,u14,cdn10,a,rand,c4,m
      double precision :: a1,a2,r80,r0,dh_ssgf,r_interval
      double precision :: dFsdr80(nbin),dFmsdr0(nbin),dr80_dr0
      integer :: iter,num_create,j,ierr
      integer :: ssgf_type  !1 for Andreas 1998, 2 for Ortiz-Suslow 2016

      double precision :: rmin10_ssgf,rmax10_ssgf
      integer :: local_seed


      !Define the bin centers and edges
      rmin10_ssgf = log10(2d-06)
      rmax10_ssgf = log10(500d-06)
      dh_ssgf = (rmax10_ssgf-rmin10_ssgf)/dble(nbin-1)

      binsdata10(1) = rmin10_ssgf
      binsdata(1) = 1.0d6*(10**binsdata10(1))
      binsdata10_edge(1) = rmin10_ssgf - dh_ssgf/2.0
      binsdata_edge(1) = 1.0d6*(10**binsdata10_edge(1))

      do i = 1,nbin-1
        binsdata10(i+1)= dh_ssgf+binsdata10(i)
        binsdata(i+1) = 1.0d6*(10**binsdata10(i+1))

        binsdata10_edge(i+1) = dh_ssgf + binsdata10_edge(i)
        binsdata_edge(i+1) = 1.0d6*(10**binsdata10_edge(i+1))
      end do

      binsdata10_edge(nbin+1) = binsdata10_edge(nbin) + dh_ssgf/2.0
      binsdata_edge(nbin+1) = 1.0d6*(10**binsdata10_edge(nbin+1))


      ! Now figure out how many particles are produced in each of
      ! those bins. This is a function of u10
      u10 = min(u10_ssgf,50.0)

      ssgf_type = 2

      !For Andreas 1998 model
      c1 = 10.0*smithssgf(u10,dble(10.0),dble(0.4))
      c2 = c1*(37.5**1.8)
      c3 = c2*(100.0**5.2)

      !For modfying with Ortiz-Suslow 2016
      m = 0.0434*u10 - 5.83
      c4 = c2*100**-2.8*(10**6*1.963*(100**1.025))**-m

      dFssum(1) = 0
      do i = 1,nbin
         r0 = binsdata(i)
         ! calculate radius at 80%RH
         r80 = 0.518*r0**0.976;
 
         if (ssgf_type.eq.1) then

             ! now apply these to Eqs. 3.5 in Andreas 1998
             if (r80 .lt. 10.0) then
               dFsdr80(i) =  smithssgf(u10,r80,dble(0.4))
             elseif ((r80 .ge. 10.0) .and. (r80 .lt. 37.5)) then
               dFsdr80(i) = c1/r80
             elseif ((r80 .ge. 37.5) .and. (r80 .lt. 100.0)) then
               dFSdr80(i) = c2*r80**-2.8
             elseif (r80 .ge. 100.0) then
               dFsdr80(i) = c3*r80**-8.0
             endif

         elseif (ssgf_type.eq.2) then

             ! Almost the same, except change the spume for > 100 for Ortiz-Suslow
             if (r80 .lt. 10.0) then
               dFsdr80(i) =  smithssgf(u10,r80,dble(0.4))
             elseif ((r80 .ge. 10.0) .and. (r80 .lt. 37.5)) then
               dFsdr80(i) = c1/r80
             elseif ((r80 .ge. 37.5) .and. (r80 .lt. 100.0)) then
               dFSdr80(i) = c2*r80**-2.8
             elseif (r80 .ge. 100.0) then
               dFsdr80(i) = c4*(10**6*1.963*r80**1.025)**m
             endif

         end if
 
         ! apply eq. 3.8 from Andreas 1998
         dFmsdr0(i) = 3.5*dFsdr80(i)*0.506*r0**-0.024
 
         if (i==1) then
           dFssum(i+1) = dFmsdr0(i)*(binsdata_edge(i+1)-binsdata_edge(i))
         elseif (i .gt. 1) then
           dFssum(i+1) = dFssum(i) + dFmsdr0(i)*(binsdata_edge(i+1)-binsdata_edge(i))
         endif
      end do

      totdrops = dFssum(nbin+1)    !totdrops at this point is # per unit area per unit time


      !Define xrange and yrange to be WHOLE domain area, to calculate the total droplet number
      xrange = dx*nx
      yrange = dy*ny

      my_reintro_tmp = xrange*yrange*time_since_inject*totdrops/drop_mult
#ifdef MPI
      my_reintro = floor(my_reintro_tmp/sngl(numprocs))

      !Processors 0 through the remainder-1 will create an extra particle
      if (myid .lt. floor(mod(my_reintro_tmp,sngl(numprocs)))) then 
         my_reintro = my_reintro + 1
      end if
#else
      my_reintro = floor(my_reintro_tmp)
#endif

      !Now that my_reintro has been calculated, reset to the LOCAL area for initializing droplet location
      xrange = xf(ni+1)-xf(1)
      yrange = yf(nj+1)-yf(1)
      zrange = 20.0

      !Update the cumulative injection statistics
      num_injected = num_injected + real(my_reintro)*drop_mult
      !$acc update device (num_injected)

      total_reintro = int(my_reintro,i8)
#ifdef MPI
      call mpi_allreduce(mpi_in_place,total_reintro,1,mpi_integer8,mpi_sum,mpi_comm_world,ierr)
#endif

#ifdef MPI
      !For deciding whether to inject more:
      call mpi_allreduce(my_reintro+nparcelsLocalActive, &
                         tot_after_reintro,1,mpi_integer8,mpi_sum, &
                         mpi_comm_world,ierr)
#else
      !Calculate the total number which will occur after injection
      tot_after_reintro = my_reintro+nparcelsLocalActive
#endif


      if (tot_after_reintro .lt. nparcelsMax) then   !Only add particles if the total number injected
                                                     !does not make the global exceed nparcelsMax
         if (myid==0 .and. total_reintro.gt.0_i8) then
            write(*,'(a,1pe15.6,a,i18)') 'DROP INJECTION: mtime=',mtime, &
                                         ' superdroplets=',total_reintro
         end if

         !$acc data copyin(dFssum,binsdata,binsdata10) create(randomNumbers,randomNumbers%state)
         !$acc update device(ngidx)
         !$acc parallel loop gang vector default(present) reduction(+:mass_injected,eng_injected,m1_injected,m2_injected) private(randomNumbers,local_seed)
         do j=1,my_reintro
            np=nparcelsLocalActive+j
            if (random_droplets) then
               ! initialize a new random number generator for each
               ! injected droplet

               !To get a repeatable sequence 
               local_seed = floor(29.*mtime) + (97*myid) + (7*j)
               call new_RandomNumberSequence(randomNumbers, local_seed)

               rand = getRandomReal(randomNumbers)
               a = totdrops*rand

               !Set the droplet radius based on the sea spray generation function (SSGF)
               !Loop over all of the discretized bins of the SSGF. Based on the random number, choose which bin to draw the radius from
               !Once a bind is identified by the conditional statement, the radius is set to a random number between the edges of the bin

               !$acc loop seq
               do i = 1,nbin
                  if ((a .gt. dFssum(i)) .and. (a .le. dFssum(i+1))) then
                     r_interval = 10**(binsdata10(i)+dh_ssgf/2.0) - 10**(binsdata10(i)-dh_ssgf/2.0)
                     rad_init = binsdata(i) + 2.0*(rand-0.5)*r_interval
                  end if 
               end do
               rad_init = rad_init*1.0e-6

               !Random location
               rand = getRandomReal(randomNumbers)
               pdata(np,prx) = xf(1)+rand*xrange
               rand = getRandomReal(randomNumbers)
               pdata(np,pry) = yf(1)+rand*yrange
               rand = getRandomReal(randomNumbers)
               pdata(np,prz) = rand*zrange
            else
               rad_init = 10.0e-6
               pdata(np,prx) = xf(1) + xrange/2.0
               pdata(np,pry) = yf(1) + yrange/2.0
               pdata(np,prz) = zrange
            end if
            pdata(np,prvpx) = 0.0
            pdata(np,prvpy) = 0.0
            pdata(np,prvpz) = 3.0 
            pdata(np,prusgs) = 0.0
            pdata(np,prvsgs) = 0.0
            pdata(np,prwsgs) = 0.0
            pdata(np,prsigsgs) = 0.0
            pdata(np,prrp) = rad_init
            pdata(np,prrp0) = rad_init
            salinity = 0.034
            pdata(np,prms) = salinity*rhow*4.0/3.0*pi*pdata(np,prrp)**3
            pdata(np,prkap) = kappa_s
            pdata(np,prtp) = tsk0   !Set to the SST
            pdata(np,prmult) = drop_mult
            pdata(np,pract) = 1.0
            !Set to something realistic so it doesn't break the stats at initiation
            pdata(np,pru) = 0.0
            pdata(np,prv) = 0.0
            pdata(np,prw) = 0.0
            pdata(np,prt) = 302.0
            pdata(np,prqv) = 0.01
            pdata(np,prprs) = 101325.0
            pdata(np,prrho) = 1.0
            pdata(np,prtime) = 0.0

            !$acc atomic capture
            idx_tmp = ngidx
            ngidx = ngidx+1  !For every new particle update the global ID 
            !$acc end atomic

            !Assign the particle IDs (both rank-local "pidx" and "procidx" -- the combination gives a unique particle ID
            pdata(np,prpidx) = transfer(idx_tmp,0.0)
            pdata(np,prprocidx) = transfer(myid,0.0)

            !Update mass_injected for statistics purposes
            mass_injected = mass_injected + (pdata(np,prms)+rhow*4.0/3.0*pi*pdata(np,prrp)**3)*pdata(np,prmult)
            eng_injected = eng_injected + (pdata(np,prms)+rhow*4.0/3.0*pi_sp*pdata(np,prrp)**3)*pdata(np,prmult)*cpl*pdata(np,prtp)
            m1_injected = m1_injected + (pdata(np,prms)+rhow*4.0/3.0*pi_sp*pdata(np,prrp)**3)*pdata(np,prmult)*pdata(np,prvpx)
            m2_injected = m2_injected + (pdata(np,prms)+rhow*4.0/3.0*pi_sp*pdata(np,prrp)**3)*pdata(np,prmult)*pdata(np,prvpy)

            call finalize_randomNumberSequence(randomNumbers)

         end do
         !$acc update host(ngidx)
         !$acc end data
         !$acc wait

         !Then once the new droplets have been added, update nparcelsLocalActive
         nparcelsLocalActive = nparcelsLocalActive + my_reintro
      else
         if (myid == 0) write(*,*) 'WARNING CANNOT ADD MORE PARTICLES, WILL EXCEED NPARCELSMAX'  
      end if

    end subroutine droplet_injection

    function smithssgf(u10,r80,vk)
    implicit none
    real :: u10
    double precision :: r80,cdn10,vk,u14
    double precision :: a1,a2,smithssgf


    ! added SEA93 function
    if (u10 .lt. 11.0) then
       cdn10 = 1.2d-3
    elseif (u10 .ge. 11) then
       cdn10 = 1d-3*(0.49 + 0.065*u10)
    end if

    ! calculate 14 m wind speed
    u14 = u10*(1 + (sqrt(cdn10)/vk)*log(14.0/10.0))
  
    a1 = 10**(0.0676*u14 + 2.43)
    a2 = 10**(0.959*sqrt(u14) - 1.476)
  

    ! calcaulate dFs/dr80 (Eq. A1 in Andreas 1998)
    smithssgf = a1*exp(-3.1*(log(r80/2.1))**2) + a2*exp(-3.3*(log(r80/9.2))**2)

    end function smithssgf

    subroutine droplet_injection_pi(pdata,xf,yf,time_since_inject,mtime,my_reintro)
      !Inject new particles according to some rule
      !Here use the pi chamber protocol: uniform aerosols at centerplane
      use input, only : nparcelsLocal,npvals,myid,ni,nj,ib,ie,jb,je, &
                        prx,pry,prz,pru,prv,prw,prvpx,prvpy,prvpz, &
                        prusgs,prvsgs,prwsgs,prsigsgs, &
                        prrp,prrp0,prtp,prms,prkap,pract,prtime, &
                        prmult,prt,prrho,prprs,prqv,prpidx,prprocidx,nparcelsLocalActive,numprocs,nparcelsMax, &
                        time_phys_H2D,time_phys_D2H,time_droplet,timestats,mytime, &
                        drop_mult,tsk0,pi_sp,myid,nx,ny,nz,dx,dy,dz
      use constants
      use MersenneTwister_mod
#ifdef MPI
      use mpi
#endif

      real, intent(inout), dimension(nparcelsLocal,npvals) :: pdata
      real, intent(in), dimension(ib:ie+1) :: xf
      real, intent(in), dimension(jb:je+1) :: yf
      real, intent(in) :: time_since_inject
      double precision, intent(in) :: mtime
      integer, intent(out) :: my_reintro
    
      integer :: i,np,idx_tmp
      integer(i8) :: tot_after_reintro,total_reintro
      integer :: sum_buf(2)

      double precision :: rad_init  !Initial radius
      double precision :: rand
      type(randomNumberSequence) :: randomNumbers

      real :: xrange,yrange,zrange
      real :: salinity
      real :: my_reintro_tmp  !A temporaray variable to store a real version of my_reintro
      
      integer :: iter,nbin,num_create,j,ierr

      integer :: local_seed

      my_reintro_tmp = 0.01*(1./60.)*(10.**6.)*time_since_inject*4 !total for a 4m^3 vol chamber

#ifdef MPI
      my_reintro = floor(my_reintro_tmp/sngl(numprocs))

      !Processors 0 through the remainder-1 will create an extra particle
      if (myid .lt. floor(mod(my_reintro_tmp,sngl(numprocs)))) then 
         my_reintro = my_reintro + 1
      end if
#else
      my_reintro = floor(my_reintro_tmp)
#endif

      !Now that my_reintro has been calculated, reset to the LOCAL area for initializing droplet location
      xrange = xf(ni+1)-xf(1)
      yrange = yf(nj+1)-yf(1)
      zrange = nz*dz/2.0

      !Update the cumulative injection statistics
      num_injected = num_injected + real(my_reintro)*drop_mult
      !$acc update device (num_injected)

      total_reintro = int(my_reintro,i8)
#ifdef MPI
      call mpi_allreduce(mpi_in_place,total_reintro,1,mpi_integer8,mpi_sum,mpi_comm_world,ierr)
#endif

#ifdef MPI
      !For deciding whether to inject more:
      call mpi_allreduce(my_reintro+nparcelsLocalActive, &
                         tot_after_reintro,1,mpi_integer8,mpi_sum, &
                         mpi_comm_world,ierr)
#else
      !Calculate the total number which will occur after injection
      tot_after_reintro = my_reintro+nparcelsLocalActive
#endif


      if (tot_after_reintro .lt. nparcelsMax) then   !Only add particles if the total number injected
                                                     !does not make the global exceed nparcelsMax
         if (myid==0 .and. total_reintro.gt.0_i8) then
            write(*,'(a,1pe15.6,a,i18)') 'DROP INJECTION: mtime=',mtime, &
                                         ' superdroplets=',total_reintro
         end if

         !$acc data create(randomNumbers,randomNumbers%state)
         !$acc update device(ngidx)
         !$acc parallel loop gang vector default(present) reduction(+:mass_injected,eng_injected,m1_injected,m2_injected) private(randomNumbers,local_seed)
         do j=1,my_reintro
            np=nparcelsLocalActive+j
            if (random_droplets) then
               ! initialize a new random number generator for each
               ! injected droplet

               !To get a repeatable sequence
               local_seed = floor(29.*mtime) + (97*myid) + (7*j)
               call new_RandomNumberSequence(randomNumbers, local_seed)

               rad_init = 2.0e-7

               !Random location
               rand = getRandomReal(randomNumbers)
               pdata(np,prx) = xf(1)+rand*xrange
               rand = getRandomReal(randomNumbers)
               pdata(np,pry) = yf(1)+rand*yrange
               pdata(np,prz) = zrange
            else
               rad_init = 1.0e-6
               pdata(np,prx) = xf(1) + xrange/2.0
               pdata(np,pry) = yf(1) + yrange/2.0
               pdata(np,prz) = zrange
            end if
            pdata(np,prvpx) = 0.0
            pdata(np,prvpy) = 0.0
            pdata(np,prvpz) = 0.0   !Specified in namelist file
            pdata(np,prusgs) = 0.0
            pdata(np,prvsgs) = 0.0
            pdata(np,prwsgs) = 0.0
            pdata(np,prsigsgs) = 0.0
            pdata(np,prrp) = rad_init
            pdata(np,prrp0) = rad_init
            salinity = 0.066
            pdata(np,prms) = salinity*rhow*4.0/3.0*pi*pdata(np,prrp)**3
            pdata(np,prkap) = kappa_s
            pdata(np,prtp) = 290.0  
            pdata(np,prmult) = drop_mult
            pdata(np,pract) = 1.0
            !Set to something realistic so it doesn't break the stats at initiation
            pdata(np,pru) = 0.0
            pdata(np,prv) = 0.0
            pdata(np,prw) = 0.0
            pdata(np,prt) = 290.0
            pdata(np,prqv) = 0.01
            pdata(np,prprs) = 101325.0
            pdata(np,prrho) = 1.0
            pdata(np,prtime) = 0.0

            !$acc atomic capture
            idx_tmp = ngidx
            ngidx = ngidx+1  !For every new particle update the global ID 
            !$acc end atomic

            !Assign the particle IDs (both rank-local "pidx" and "procidx" -- the combination gives a unique particle ID
            pdata(np,prpidx) = transfer(idx_tmp,0.0)
            pdata(np,prprocidx) = transfer(myid,0.0)

            !Update mass_injected for statistics purposes
            mass_injected = mass_injected + (pdata(np,prms)+rhow*4.0/3.0*pi*pdata(np,prrp)**3)*pdata(np,prmult)
            eng_injected = eng_injected + (pdata(np,prms)+rhow*4.0/3.0*pi_sp*pdata(np,prrp)**3)*pdata(np,prmult)*cpl*pdata(np,prtp)
            m1_injected = m1_injected + (pdata(np,prms)+rhow*4.0/3.0*pi_sp*pdata(np,prrp)**3)*pdata(np,prmult)*pdata(np,prvpx)
            m2_injected = m2_injected + (pdata(np,prms)+rhow*4.0/3.0*pi_sp*pdata(np,prrp)**3)*pdata(np,prmult)*pdata(np,prvpy)

            call finalize_randomNumberSequence(randomNumbers)

         end do
         !$acc update host(ngidx)
         !$acc end data
         !$acc wait
         !Then once the new droplets have been added, update nparcelsLocalActive
         nparcelsLocalActive = nparcelsLocalActive + my_reintro
      else
         if (myid == 0) write(*,*) 'WARNING CANNOT ADD MORE PARTICLES, WILL EXCEED NPARCELSMAX'  
      end if

    end subroutine droplet_injection_pi

    subroutine droplet_fallout_reinjection(pdata,xf,yf,num_fallout,mtime,my_reintro)
      !Re-inject one testcase 17 droplet for each droplet removed on this MPI rank.
      use input, only : nparcelsLocal,npvals,myid,ni,nj,ib,ie,jb,je, &
                        prx,pry,prz,pru,prv,prw,prvpx,prvpy,prvpz, &
                        prusgs,prvsgs,prwsgs,prsigsgs, &
                        prrp,prrp0,prtp,prms,prkap,pract,prtime, &
                        prmult,prt,prrho,prprs,prqv,prpidx,prprocidx,nparcelsLocalActive, &
                        drop_mult,pi_sp,maxz
      use constants
      use MersenneTwister_mod
#ifdef MPI
      use mpi
#endif

      implicit none

      real, intent(inout), dimension(nparcelsLocal,npvals) :: pdata
      real, intent(in), dimension(ib:ie+1) :: xf
      real, intent(in), dimension(jb:je+1) :: yf
      integer, intent(in) :: num_fallout
      double precision, intent(in) :: mtime
      integer, intent(out) :: my_reintro

      integer :: j,np,idx_tmp
      integer :: local_seed
      integer(i8) :: total_reintro
#ifdef MPI
      integer :: ierr
#endif
      real :: xrange,yrange,zrange
      double precision :: rand
      type(randomNumberSequence) :: randomNumbers

      my_reintro = num_fallout

      xrange = xf(ni+1)-xf(1)
      yrange = yf(nj+1)-yf(1)
      zrange = maxz

      if (my_reintro.gt.0 .and. nparcelsLocalActive + my_reintro .le. nparcelsLocal) then
         total_reintro = int(my_reintro,i8)
      else
         total_reintro = 0_i8
      end if
#ifdef MPI
      call mpi_allreduce(mpi_in_place,total_reintro,1,mpi_integer8,mpi_sum,mpi_comm_world,ierr)
#endif
      if (myid==0 .and. total_reintro.gt.0_i8) then
         write(*,'(a,1pe15.6,a,i18)') 'DROP REINJECT: mtime=',mtime, &
                                      ' superdroplets=',total_reintro
      end if

      if (my_reintro .le. 0) return

      if (nparcelsLocalActive + my_reintro .le. nparcelsLocal) then
         num_injected = num_injected + real(my_reintro)*drop_mult
         !$acc update device (num_injected)

         !$acc data create(randomNumbers,randomNumbers%state)
         !$acc update device(ngidx)
         !$acc parallel loop gang vector default(present) reduction(+:mass_injected,eng_injected,m1_injected,m2_injected) private(randomNumbers,local_seed)
         do j=1,my_reintro
            np=nparcelsLocalActive+j

            local_seed = floor(29.*mtime) + (97*myid) + (7*j)
            call new_RandomNumberSequence(randomNumbers, local_seed)

            rand = getRandomReal(randomNumbers)
            pdata(np,prx) = xf(1)+rand*xrange
            rand = getRandomReal(randomNumbers)
            pdata(np,pry) = yf(1)+rand*yrange
            rand = getRandomReal(randomNumbers)
            pdata(np,prz) = rand*zrange

            pdata(np,prvpx) = 0.0
            pdata(np,prvpy) = 0.0
            pdata(np,prvpz) = 0.0
            pdata(np,prusgs) = 0.0
            pdata(np,prvsgs) = 0.0
            pdata(np,prwsgs) = 0.0
            pdata(np,prsigsgs) = 0.0
            pdata(np,prkap) = 0.6
            call lognormal_droplet(pdata(np,prrp),pdata(np,prms),pdata(np,prkap),randomNumbers)
            pdata(np,prrp0) = pdata(np,prrp)
            pdata(np,prtp) = 290.0
            pdata(np,prmult) = drop_mult
            pdata(np,pract) = 1.0
            pdata(np,pru) = 0.0
            pdata(np,prv) = 0.0
            pdata(np,prw) = 0.0
            pdata(np,prt) = 290.0
            pdata(np,prqv) = 0.01
            pdata(np,prprs) = 101325.0
            pdata(np,prrho) = 1.0
            pdata(np,prtime) = 0.0

            !$acc atomic capture
            idx_tmp = ngidx
            ngidx = ngidx+1
            !$acc end atomic

            pdata(np,prpidx) = transfer(idx_tmp,0.0)
            pdata(np,prprocidx) = transfer(myid,0.0)

            mass_injected = mass_injected + (pdata(np,prms)+rhow*4.0/3.0*pi*pdata(np,prrp)**3)*pdata(np,prmult)
            eng_injected = eng_injected + (pdata(np,prms)+rhow*4.0/3.0*pi_sp*pdata(np,prrp)**3)*pdata(np,prmult)*cpl*pdata(np,prtp)
            m1_injected = m1_injected + (pdata(np,prms)+rhow*4.0/3.0*pi_sp*pdata(np,prrp)**3)*pdata(np,prmult)*pdata(np,prvpx)
            m2_injected = m2_injected + (pdata(np,prms)+rhow*4.0/3.0*pi_sp*pdata(np,prrp)**3)*pdata(np,prmult)*pdata(np,prvpy)

            call finalize_randomNumberSequence(randomNumbers)
         end do
         !$acc update host(ngidx)
         !$acc end data

         nparcelsLocalActive = nparcelsLocalActive + my_reintro
      else
         if (myid == 0) write(*,*) 'WARNING CANNOT REINJECT PARTICLES, WILL EXCEED NPARCELSLOCAL'
         my_reintro = 0
      end if

    end subroutine droplet_fallout_reinjection

    subroutine initialize_droplet_histograms

    implicit none

    !For initializing droplet histogram stat arrays
    integer :: i

    !For the radius histograms
    rmin = 1.0e-8
    rmax = 1.0e-3
    rmin10 = log10(rmin)
    rmax10 = log10(rmax)

    dhrad = (rmax10-rmin10)/(nbins-1)

    bins_radius(1) = rmin10-dhrad
    do i=1,nbins-1
       bins_radius(i+1) = bins_radius(i) + dhrad
    end do 

    !For the residence time histograms
    restime_min = 1.0e0
    restime_max = 1.0e5
    restime_min10 = log10(restime_min)
    restime_max10 = log10(restime_max)

    dhres = (restime_max10-restime_min10)/(nbins-1)

    bins_restime(1) = restime_min10-dhres
    do i=1,nbins-1
       bins_restime(i+1) = bins_restime(i) + dhres
    end do

    !Initialize histogram to zero
    !(only those which accumulate between dropdiag I/O)
    hist_restime = 0.0
    hist_fallrad = 0.0
    num_destroyed = 0.0
    mass_destroyed = 0.0
    mass_evap = 0.0
    mass_dpten = 0.0
    mass_reentry = 0.0
    eng_reentry = 0.0
    m1_reentry = 0.0
    m2_reentry = 0.0
    eng_destroyed = 0.0
    m1_destroyed = 0.0
    m2_destroyed = 0.0
    num_injected = 0.0
    mass_injected = 0.0
    eng_injected = 0.0
    m1_injected = 0.0
    m2_injected = 0.0
    num100 = 0.0
    num1000 = 0.0

    !$acc update device(hist_restime,hist_fallrad,restime_min, &
    !$acc               restime_max,restime_min10,restime_max10, &
    !$acc               dhres,dhrad,rmin,rmax,rmin10,rmax10, &
    !$acc               num_destroyed,mass_destroyed,mass_evap,mass_dpten,num_injected,mass_injected, &
    !$acc               eng_destroyed,m1_destroyed,m2_destroyed,eng_injected,m1_injected,m2_injected, &
    !$acc               mass_reentry,eng_reentry,m1_reentry,m2_reentry, &
    !$acc               num100,num1000)

    end subroutine initialize_droplet_histograms


#ifdef NETCDF

      subroutine writedropdiag_nc(nrec,nbins,&
                                  rtime,tnumpart,tnummult,tnumaerosol,tnumdrop,tmasspart,radavg,radsqr,radmin,radmax,Tpavg,Tpsqr,Tpmin,Tpmax,Tfavg,qfavg,prsavg,rhoavg,&
                                  zhvec,numconc,sd_numconc,massconc,vp1mean,vp2mean,vp3mean,uf1mean,uf2mean,uf3mean,&
                                  usgsmean,vsgsmean,wsgsmean,sigm_smean,fsmean,&
                                  vp1msqr,vp2msqr,vp3msqr,m1src,m2src,m3src,Tpsrc,qvsrc,rhovsrc,Tf,qf,Tpmean,Tpmsqr,&
                                  radmean,radmsqr,qfsat,qstarmean,kmoist,mse,wk,multnumrz,vp3meanrz,tnumpart_r)
      use input
      use constants
      use netcdf
      use writeout_nc_module
      implicit none

      integer, intent(inout) :: nrec
      real,    intent(in)    :: rtime,radavg,radsqr,radmin,radmax,Tpavg,Tpsqr,Tpmin,Tpmax,Tfavg,qfavg,prsavg,rhoavg,tnummult,tnumaerosol,tnumdrop,tmasspart
      real,    intent(in)    :: zhvec(nk),numconc(nk),sd_numconc(nk),massconc(nk),vp1mean(nk),vp2mean(nk),vp3mean(nk),vp1msqr(nk),vp2msqr(nk),vp3msqr(nk),m1src(nk),m2src(nk),m3src(nk),Tpsrc(nk),qvsrc(nk),rhovsrc(nk),Tf(nk),qf(nk),Tpmean(nk),Tpmsqr(nk),radmean(nk),radmsqr(nk),qfsat(nk),qstarmean(nk),uf1mean(nk),uf2mean(nk),uf3mean(nk),kmoist(nk),mse(nk),wk(nk)
      real,    intent(in)    :: usgsmean(nk),vsgsmean(nk),wsgsmean(nk),sigm_smean(nk),fsmean(nk)
      real,    intent(in)    :: multnumrz(nk,nbins),vp3meanrz(nk,nbins)
      real,    intent(in)    :: tnumpart_r(nbins)
      integer, intent(in)    :: nbins
      real, intent(in) :: tnumpart

      integer :: i,ncid,status,dimid,varid,time_index,timeid,tfile,zhid,binsid
      logical :: allinfo

      if( myid.eq.0 ) print *,'  Entering writedropdiag_nc '

      do i=1,maxstring
        string(i:i) = ' '
      enddo

      string = 'cm1out_dropdiag.nc'

    if(myid.eq.0) print *,string

    allinfo = .false.
    IF(nrec.eq.1) allinfo=.true.

    IF( nrec.ne.1 )THEN
      ! cm1r18:  Try to open file.
      !          If error, set nrec to 1 and write all info.
      status = nf90_open( path=string , mode=nf90_write , ncid=ncid )
      if( status.eq.nf90_noerr )then
        ! no error, file exists.  Get number of time levels in file:
        call disp_err( nf90_inq_dimid(ncid,'time',timeid) , .true. )
        call disp_err( nf90_inquire_dimension(ncid=ncid,dimid=timeid,len=tfile), .true. )
        if( (tfile+1).lt.nrec )then
          if(myid.eq.0) print *,'  tfile,nrec = ',tfile,nrec
          nrec = tfile+1
        endif
      else
        ! if error opening file, then write all info:
        if(myid.eq.0) print *,'  status = ',status
!!!        if(myid.eq.0) print *,nf90_strerror(status)
        allinfo = .true.
        nrec = 1
      endif
    ENDIF

    if( myid.eq.0 ) print *,'  nrec = ',nrec


  allinfo2:  IF( allinfo )THEN
    ! Definitions/descriptions:

      if( myid.eq.0 ) print *,'  calling nf90_create '
      ! must do this for netcdf 4.0 (it seems) !
      call disp_err( nf90_create(path=string,cmode=0,ncid=ncid) , .true. )

    call disp_err( nf90_def_dim(ncid,"time",nf90_unlimited,timeid) , .true. )
    call disp_err( nf90_def_dim(ncid,"zh",nk,zhid) , .true. )
    call disp_err( nf90_def_dim(ncid,"bins",nbins,binsid) , .true. )

    call disp_err( nf90_def_var(ncid,"time",nf90_float,(/timeid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","time") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","seconds") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"axis","T") , .true. )

    call disp_err( nf90_def_var(ncid,"zh",nf90_float,(/zhid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","height of scalar levels") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","m") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"axis","Z") , .true. )

    !Unlike statpack and other nc writes, doing these manually since they aren't all the same size

    !!0th order
    call disp_err( nf90_def_var(ncid,"tnumpart",nf90_float,timeid,varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Total number of computational droplets in domain") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","No units") , .true. )

    call disp_err( nf90_def_var(ncid,"tnummult",nf90_float,timeid,varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Total number of droplets in domain (including multiplicity)") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","No units") , .true. )

    call disp_err( nf90_def_var(ncid,"tnumaerosol",nf90_float,timeid,varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Total number of unactivated aerosols in domain (including multiplicity)") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","No units") , .true. )

    call disp_err( nf90_def_var(ncid,"tnumdrop",nf90_float,timeid,varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Total number of activated droplets in domain (including multiplicity)") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","No units") , .true. )

    call disp_err( nf90_def_var(ncid,"tmasspart",nf90_float,timeid,varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Total mass of liquid water in droplets (including multiplicity)") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","kg") , .true. )

    call disp_err( nf90_def_var(ncid,"radavg",nf90_float,timeid,varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Average droplet radius for all droplet") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","m") , .true. )

    call disp_err( nf90_def_var(ncid,"radsqr",nf90_float,timeid,varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Average square droplet radius for all droplets") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","m^2") , .true. )

    call disp_err( nf90_def_var(ncid,"radmin",nf90_float,timeid,varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Minimum droplet radius for all droplets") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","m") , .true. )

    call disp_err( nf90_def_var(ncid,"radmax",nf90_float,timeid,varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Maximum droplet radius for all droplets") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","m") , .true. )

    call disp_err( nf90_def_var(ncid,"Tpavg",nf90_float,timeid,varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Average droplet temperature for all droplets") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","K") , .true. )

    call disp_err( nf90_def_var(ncid,"Tpsqr",nf90_float,timeid,varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Average square droplet temperature for all droplets") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","K^2") , .true. )

    call disp_err( nf90_def_var(ncid,"Tpmin",nf90_float,timeid,varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Minimum droplet temperature for all droplets") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","K") , .true. )

    call disp_err( nf90_def_var(ncid,"Tpmax",nf90_float,timeid,varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Maximum droplet temperature for all droplets") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","K") , .true. )

    call disp_err( nf90_def_var(ncid,"Tfavg",nf90_float,timeid,varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Average air temperature seen by droplet for all droplets") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","K") , .true. )

    call disp_err( nf90_def_var(ncid,"qfavg",nf90_float,timeid,varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Average water vapor mixing ratio qv seen by droplet for all droplets") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","kg/kg") , .true. )

    call disp_err( nf90_def_var(ncid,"prsavg",nf90_float,timeid,varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Average air pressure seen by droplet for all droplets") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","Pa") , .true. )

    call disp_err( nf90_def_var(ncid,"rhoavg",nf90_float,timeid,varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Average air density seen by droplet for all droplets") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","kg/m^3") , .true. )

    call disp_err( nf90_def_var(ncid,"num100",nf90_float,timeid,varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Number of droplets which failed the 1st round Newton iteration since last droplet_diag") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","No units") , .true. )

    call disp_err( nf90_def_var(ncid,"num1000",nf90_float,timeid,varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Number of droplets which failed the 2st round Levenberg-Marquardt iteration since last droplet_diag") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","No units") , .true. )

    call disp_err( nf90_def_var(ncid,"u10_ssgf",nf90_double,timeid,varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","10-meter wind speed used in the spray SSGF") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","m/s3") , .true. )

    call disp_err( nf90_def_var(ncid,"num_destroyed",nf90_float,timeid,varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Number of droplets that fell out since last entry") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","#") , .true. )

    call disp_err( nf90_def_var(ncid,"mass_destroyed",nf90_float,timeid,varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Mass droplets that fell out since last entry") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","kg") , .true. )

    call disp_err( nf90_def_var(ncid,"mass_evap",nf90_float,timeid,varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Total change in mass due to evaporation since last entry") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","kg") , .true. )

    call disp_err( nf90_def_var(ncid,"mass_dpten",nf90_float,timeid,varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Total change in vapor source due to evaporation since last entry") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","kg") , .true. )

    call disp_err( nf90_def_var(ncid,"mass_reentry",nf90_float,timeid,varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Net change in re-entrant droplet mass since last entry") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","kg") , .true. )

    call disp_err( nf90_def_var(ncid,"eng_reentry",nf90_float,timeid,varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Net change in re-entrant droplet energy since last entry") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","kg") , .true. )

    call disp_err( nf90_def_var(ncid,"m1_reentry",nf90_float,timeid,varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Net change in re-entrant droplet x-momentum since last entry") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","kg") , .true. )

    call disp_err( nf90_def_var(ncid,"m2_reentry",nf90_float,timeid,varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Net change in re-entrant droplet y-momentum since last entry") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","kg") , .true. )

    call disp_err( nf90_def_var(ncid,"eng_destroyed",nf90_float,timeid,varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Total internal energy in droplets that fell out since last entry") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","J") , .true. )

    call disp_err( nf90_def_var(ncid,"m1_destroyed",nf90_float,timeid,varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Total x-momentum in droplets that fell out since last entry") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","kg-m/s") , .true. )

    call disp_err( nf90_def_var(ncid,"m2_destroyed",nf90_float,timeid,varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Total y-momentum in droplets that fell out since last entry") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","kg-m/s") , .true. )

    call disp_err( nf90_def_var(ncid,"num_injected",nf90_float,timeid,varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Number of droplets injected since last entry") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","#") , .true. )

    call disp_err( nf90_def_var(ncid,"mass_injected",nf90_float,timeid,varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Total mass of droplets injected since last entry") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","kg") , .true. )

    call disp_err( nf90_def_var(ncid,"eng_injected",nf90_float,timeid,varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Total internal energy of droplets injected since last entry") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","J") , .true. )

    call disp_err( nf90_def_var(ncid,"m1_injected",nf90_float,timeid,varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Total x-momentum of droplets injected since last entry") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","kg-m/s") , .true. )

    call disp_err( nf90_def_var(ncid,"m2_injected",nf90_float,timeid,varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Total y-momentum of droplets injected since last entry") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","kg-m/s") , .true. )


    !!1st order (horizontal averages)
    call disp_err( nf90_def_var(ncid,"numconc",nf90_float,(/zhid,timeid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Horizontally averaged number concentration of droplets (including multiplicity)") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","#/m^3") , .true. )

    call disp_err( nf90_def_var(ncid,"sd_numconc",nf90_float,(/zhid,timeid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Horizontally averaged number concentration of superdroplets") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","#/m^3") , .true. )

    call disp_err( nf90_def_var(ncid,"massconc",nf90_float,(/zhid,timeid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Horizontally averaged mass concentration of droplets (including multiplicity)") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","#/m^3") , .true. )

    call disp_err( nf90_def_var(ncid,"vp1mean",nf90_float,(/zhid,timeid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Horizontally averaged droplet u-velocity") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","m/s") , .true. )
    
    call disp_err( nf90_def_var(ncid,"vp2mean",nf90_float,(/zhid,timeid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Horizontally averaged droplet v-velocity") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","m/s") , .true. )
    
    call disp_err( nf90_def_var(ncid,"vp3mean",nf90_float,(/zhid,timeid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Horizontally averaged droplet w-velocity") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","m/s") , .true. )
    
    call disp_err( nf90_def_var(ncid,"uf1mean",nf90_float,(/zhid,timeid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Horizontally averaged droplet u-velocity seen by particle") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","m/s") , .true. )
    
    call disp_err( nf90_def_var(ncid,"uf2mean",nf90_float,(/zhid,timeid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Horizontally averaged droplet v-velocity seen by particle") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","m/s") , .true. )
    
    call disp_err( nf90_def_var(ncid,"uf3mean",nf90_float,(/zhid,timeid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Horizontally averaged droplet w-velocity seen by particle") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","m/s") , .true. )

    call disp_err( nf90_def_var(ncid,"usgsmean",nf90_float,(/zhid,timeid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Horizontally averaged droplet SGS u-velocity") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","m/s") , .true. )

    call disp_err( nf90_def_var(ncid,"vsgsmean",nf90_float,(/zhid,timeid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Horizontally averaged droplet SGS v-velocity") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","m/s") , .true. )

    call disp_err( nf90_def_var(ncid,"wsgsmean",nf90_float,(/zhid,timeid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Horizontally averaged droplet SGS w-velocity") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","m/s") , .true. )

    call disp_err( nf90_def_var(ncid,"sigm_smean",nf90_float,(/zhid,timeid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Horizontally averaged droplet SGS velocity variance sigm_s") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","m^2/s^2") , .true. )

    call disp_err( nf90_def_var(ncid,"fsmean",nf90_float,(/zhid,timeid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Horizontally averaged SGS turbulence fraction") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","1") , .true. )
    
    call disp_err( nf90_def_var(ncid,"vp1msqr",nf90_float,(/zhid,timeid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Droplet mean squared u-velocity <up^2>") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","m^2/s^2") , .true. )
    
    call disp_err( nf90_def_var(ncid,"vp2msqr",nf90_float,(/zhid,timeid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Droplet mean squared v-velocity <vp^2>") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","m^2/s^2") , .true. )
    
    call disp_err( nf90_def_var(ncid,"vp3msqr",nf90_float,(/zhid,timeid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Droplet mean squared w-velocity <wp^2>") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","m^2/s^2") , .true. )

    call disp_err( nf90_def_var(ncid,"m1src",nf90_float,(/zhid,timeid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Droplet-induced tendency term for the u-velocity") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","m/s^2") , .true. )

    call disp_err( nf90_def_var(ncid,"m2src",nf90_float,(/zhid,timeid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Droplet-induced tendency term for the v-velocity") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","m/s^2") , .true. )

    call disp_err( nf90_def_var(ncid,"m3src",nf90_float,(/zhid,timeid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Droplet-induced tendency term for the w-velocity") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","m/s^2") , .true. )

    call disp_err( nf90_def_var(ncid,"Tpsrc",nf90_float,(/zhid,timeid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Droplet-induced tendency term for the potential temperature") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","K/s") , .true. )

    call disp_err( nf90_def_var(ncid,"qvsrc",nf90_float,(/zhid,timeid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Droplet-induced tendency term for the water vapor mixing ratio") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","(kg/kg)/s") , .true. )

    call disp_err( nf90_def_var(ncid,"rhovsrc",nf90_float,(/zhid,timeid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Droplet-induced tendency term for the water vapor density") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","(kg/m^3)/s") , .true. )

    call disp_err( nf90_def_var(ncid,"Tf",nf90_float,(/zhid,timeid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Average temperature at droplet location") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","K") , .true. )

    call disp_err( nf90_def_var(ncid,"qf",nf90_float,(/zhid,timeid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Average water vapor mixing ratio at droplet location") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","kg/kg") , .true. )

    call disp_err( nf90_def_var(ncid,"Tpmean",nf90_float,(/zhid,timeid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Horizontally averaged droplet temperature") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","K") , .true. )

    call disp_err( nf90_def_var(ncid,"Tpmsqr",nf90_float,(/zhid,timeid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Droplet mean squared temperature <Tp^2>") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","K^2") , .true. )

    call disp_err( nf90_def_var(ncid,"radmean",nf90_float,(/zhid,timeid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Horizontally averaged droplet radius") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","m") , .true. )

    call disp_err( nf90_def_var(ncid,"radmsqr",nf90_float,(/zhid,timeid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Droplet mean squared droplet radius <rp^2>") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","m^2") , .true. )

    call disp_err( nf90_def_var(ncid,"qfsat",nf90_float,(/zhid,timeid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Horizontally averaged ambient saturation water vapor mixing ratio at droplet location") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","kg/kg") , .true. )

    call disp_err( nf90_def_var(ncid,"qstarmean",nf90_float,(/zhid,timeid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Horizontally averaged saturation water vapor mixing ratio on droplet surface") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","kg/kg") , .true. )

    call disp_err( nf90_def_var(ncid,"kmoist",nf90_float,(/zhid,timeid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Horizontally averaged moist enthalpy, including droplets") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","J/kg") , .true. )

    call disp_err( nf90_def_var(ncid,"mse",nf90_float,(/zhid,timeid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Horizontally averaged moist static energy, including droplets") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","J/kg") , .true. )

    call disp_err( nf90_def_var(ncid,"wk",nf90_float,(/zhid,timeid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Horizontally averaged moist enthalpy flux <w'k'>") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","J-m/kg-s ") , .true. )



    !!2nd order (radiue-height statistics)
    call disp_err( nf90_def_var(ncid,"multnumrz",nf90_float,(/zhid,binsid,timeid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Size-resolved particle number concentration with height") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","#/m^3 ") , .true. )

    call disp_err( nf90_def_var(ncid,"vp3meanrz",nf90_float,(/zhid,binsid,timeid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Size-resolved particle average vertical velocity with height") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","m/s ") , .true. )



    !!Histograms (histograms of various droplet properties)
    call disp_err( nf90_def_var(ncid,"bins_radius",nf90_float,(/binsid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","histogram bin centers for radius") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","m") , .true. )

    call disp_err( nf90_def_var(ncid,"bins_restime",nf90_float,(/binsid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","histogram bin centers for droplet residence time") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","s") , .true. )

    call disp_err( nf90_def_var(ncid,"hist_radius",nf90_float,(/binsid,timeid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","total count for each bin") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","#") , .true. )

    call disp_err( nf90_def_var(ncid,"hist_dry_radius",nf90_float,(/binsid,timeid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","total count for each dry-radius bin from solute mass") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","#") , .true. )

    call disp_err( nf90_def_var(ncid,"hist_radius10",nf90_float,(/binsid,timeid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","total count for each bin only for those under 10m") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","#") , .true. )

    call disp_err( nf90_def_var(ncid,"hist_restime",nf90_float,(/binsid,binsid,timeid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","total count for each residence time bin and radius bin over the past statfrq time") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","#") , .true. )

    call disp_err( nf90_def_var(ncid,"hist_fallrad",nf90_float,(/binsid,timeid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","total radius count of droplet which fell out over the past statfrq time") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","#") , .true. )

    call disp_err( nf90_def_var(ncid,"tnumpart_r",nf90_float,(/binsid,timeid/),varid) , .true. )
    call disp_err( nf90_put_att(ncid,varid,"long_name","Droplet count as a function of radius, binned by bins_radius") , .true. )
    call disp_err( nf90_put_att(ncid,varid,"units","#") , .true. )


    call disp_err( nf90_put_att(ncid,NF90_GLOBAL,'CM1 version',trim(cm1version)) , .true. )
    call disp_err( nf90_enddef(ncid=ncid) , .true. )

  ENDIF  allinfo2


  !---------------------------------------------------------------------
    ! Write data:

    time_index = nrec

    call disp_err( nf90_inq_varid(ncid,'time',timeid) , .true. )
    call disp_err( nf90_put_var(ncid,timeid,rtime,(/time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,'zh',zhid) , .true. )
    call disp_err( nf90_put_var(ncid,zhid,zhvec,(/1/)) , .true. )


    !!0th order
    call disp_err( nf90_inq_varid(ncid,"tnumpart",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,tnumpart,(/time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"tnummult",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,tnummult,(/time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"tnumaerosol",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,tnumaerosol,(/time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"tnumdrop",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,tnumdrop,(/time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"tmasspart",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,tmasspart,(/time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"radavg",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,radavg,(/time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"radsqr",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,radsqr,(/time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"radmin",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,radmin,(/time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"radmax",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,radmax,(/time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"Tpavg",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,Tpavg,(/time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"Tpsqr",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,Tpsqr,(/time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"Tpmin",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,Tpmin,(/time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"Tpmax",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,Tpmax,(/time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"Tfavg",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,Tfavg,(/time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"qfavg",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,qfavg,(/time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"prsavg",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,prsavg,(/time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"rhoavg",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,rhoavg,(/time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"num100",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,num100,(/time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"num1000",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,num1000,(/time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"u10_ssgf",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,u10_ssgf,(/time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"num_destroyed",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,num_destroyed,(/time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"mass_destroyed",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,mass_destroyed,(/time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"mass_reentry",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,mass_reentry,(/time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"eng_reentry",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,eng_reentry,(/time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"m1_reentry",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,m1_reentry,(/time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"m2_reentry",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,m2_reentry,(/time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"mass_evap",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,real(mass_evap),(/time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"mass_dpten",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,real(mass_dpten),(/time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"eng_destroyed",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,eng_destroyed,(/time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"m1_destroyed",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,m1_destroyed,(/time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"m2_destroyed",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,m2_destroyed,(/time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"num_injected",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,num_injected,(/time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"mass_injected",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,mass_injected,(/time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"eng_injected",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,eng_injected,(/time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"m1_injected",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,m1_injected,(/time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"m2_injected",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,m2_injected,(/time_index/)) , .true. )

    !!1st order
    call disp_err( nf90_inq_varid(ncid,"numconc",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,numconc,(/1,time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"sd_numconc",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,sd_numconc,(/1,time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"massconc",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,massconc,(/1,time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"vp1mean",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,vp1mean,(/1,time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"vp2mean",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,vp2mean,(/1,time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"vp3mean",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,vp3mean,(/1,time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"uf1mean",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,uf1mean,(/1,time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"uf2mean",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,uf2mean,(/1,time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"uf3mean",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,uf3mean,(/1,time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"usgsmean",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,usgsmean,(/1,time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"vsgsmean",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,vsgsmean,(/1,time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"wsgsmean",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,wsgsmean,(/1,time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"sigm_smean",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,sigm_smean,(/1,time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"fsmean",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,fsmean,(/1,time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"vp1msqr",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,vp1msqr,(/1,time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"vp2msqr",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,vp2msqr,(/1,time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"vp3msqr",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,vp3msqr,(/1,time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"m1src",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,m1src,(/1,time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"m2src",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,m2src,(/1,time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"m3src",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,m3src,(/1,time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"Tpsrc",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,Tpsrc,(/1,time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"qvsrc",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,qvsrc,(/1,time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"rhovsrc",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,rhovsrc,(/1,time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"Tf",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,Tf,(/1,time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"qf",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,qf,(/1,time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"Tpmean",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,Tpmean,(/1,time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"Tpmsqr",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,Tpmsqr,(/1,time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"radmean",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,radmean,(/1,time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"radmsqr",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,radmsqr,(/1,time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"qfsat",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,qfsat,(/1,time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"qstarmean",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,qstarmean,(/1,time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"kmoist",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,kmoist,(/1,time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"mse",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,mse,(/1,time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"wk",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,wk,(/1,time_index/)) , .true. )

    !!2nd order
    call disp_err( nf90_inq_varid(ncid,"multnumrz",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,multnumrz,(/1,1,time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"vp3meanrz",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,vp3meanrz,(/1,1,time_index/)) , .true. )


    !!Histograms
    call disp_err( nf90_inq_varid(ncid,"bins_radius",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,bins_radius,(/1/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"bins_restime",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,bins_restime,(/1/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"hist_radius",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,hist_radius,(/1,time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"hist_dry_radius",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,hist_dry_radius,(/1,time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"hist_radius10",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,hist_radius10,(/1,time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"hist_restime",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,hist_restime,(/1,1,time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"hist_fallrad",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,hist_fallrad,(/1,time_index/)) , .true. )

    call disp_err( nf90_inq_varid(ncid,"tnumpart_r",varid) , .true. )
    call disp_err( nf90_put_var(ncid,varid,tnumpart_r,(/1,time_index/)) , .true. )

    ! close file

    call disp_err( nf90_close(ncid) , .true. )

    ! all done

      if( myid.eq.0 ) print *,'  Leaving writedropdiag_nc '

   end subroutine writedropdiag_nc


#endif

!ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
!ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
!ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc

      subroutine check_droplet_ownership(x3d,y3d,xf,yf,is_local, &
                                         neighbor,errcode)

      ! This subroutine will check if a droplet falls into this MPI region or not
      !     Exception case:
      !       - if droplet is on a tile boundary, let the eastmost/northmost tile own it
      !       - if droplet is on the northmost or eastmost boundary of the whole domain,
      !         let the MPI rank which inclues that boundary owns it
      !
      ! Optionally, this subroutine will also calculate which neighbor
      ! a droplet will move to.

      !$acc routine seq

      use input, only : ni,nj,ib,ie,jb,je,ngxy,nx,ny,dx,dy,mywest, &
                        mysw,mynw,myeast,myse,myne,mysouth,mynorth
      use constants, only : undefined_index

      implicit none

      real, intent(in) :: x3d, y3d
      real, dimension(ib:ie+1), intent(in) :: xf
      real, dimension(jb:je+1), intent(in) :: yf
      logical, intent(out) :: is_local
      integer, intent(out), optional :: neighbor, errcode

      ! Local variable

      is_local = .false.

      ! normal case: a droplet falls within the domain or
      !              on the westmost/southmost boundary
      if ( x3d .ge. xf(1) .and. x3d .le. xf(ni+1) .and. &
           y3d .ge. yf(1) .and. y3d .le. yf(nj+1) ) then
         is_local = .true.
      end if

      ! check optional input
      if ( present(neighbor) ) then
         if ( .not. present(errcode) ) then
            stop "neighbor is provided but errcode is not provided ..."
         end if
      end if
      if ( present(errcode) ) then
         if ( .not. present(neighbor) ) then
            stop "errcode is provided but neighbor is not provided ..."
         end if
      end if

      if ( present(neighbor) ) then
         if ( is_local ) then 
            neighbor = undefined_index
            return
         end if
         if ( x3d .lt. xf(1) .and. y3d .ge. yf(1) .and. &
              y3d .le. yf(nj+1) ) then
            if ( x3d .lt. xf(1)-dx*ni ) then
               errcode = 50
            end if
            neighbor = mywest
         else if ( x3d .lt. xf(1) .and. y3d .lt. yf(1) ) then
            if ( x3d .lt. xf(1)-dx*ni .or. y3d .lt. yf(1)-dy*nj ) then
               errcode = 50
            end if
            neighbor = mysw
         else if ( x3d .lt. xf(1) .and. y3d .gt. yf(nj+1) ) then
            if ( x3d .lt. xf(1)-dx*ni .or. y3d .gt. yf(nj+1)+dy*nj ) then
               errcode = 50
            end if
            neighbor = mynw
         else if ( x3d .gt. xf(ni+1) .and. y3d .ge. yf(1) .and. &
                   y3d .le. yf(nj+1) ) then
            if ( x3d .gt. xf(ni+1)+dx*ni ) then
               errcode = 50
            end if
            neighbor = myeast
         else if ( x3d .gt. xf(ni+1) .and. y3d .lt. yf(1) ) then
            if ( x3d .gt. xf(ni+1)+dx*ni .or. y3d .lt. yf(1)-dy*nj ) then
               errcode = 50
            end if
            neighbor = myse
         else if ( x3d .gt. xf(ni+1) .and. y3d .gt. yf(nj+1) ) then
            if ( x3d .gt. xf(ni+1)+dx*ni .or. y3d .gt. yf(nj+1)+dy*nj ) then
               errcode = 50
            end if
            neighbor = myne
         else if ( x3d .ge. xf(1) .and. x3d .le. xf(ni+1) .and. &
                   y3d .lt. yf(1) ) then
            if ( y3d .lt. yf(1)-dy*nj ) then
               errcode = 50
            end if
            neighbor = mysouth
         else if ( x3d .ge. xf(1) .and. x3d .le. xf(ni+1) .and. &
                   y3d .gt. yf(nj+1) ) then
            if ( y3d .gt. yf(nj+1)+dy*nj ) then
               errcode = 50
            end if
            neighbor = mynorth
         else
            ! This condition should never be entered
            errcode = 12345
         end if     ! if statement for neighbor check
      end if        ! if "neighbor" is present

      end subroutine check_droplet_ownership

!ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
!ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
!ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc

recursive subroutine quicksort(a, first, last)
     implicit none
  integer  a(:), x, t
  integer first, last
  integer i, j

  x = a( (first+last) / 2 )
  i = first
  j = last
  do
     do while (a(i) < x)
        i=i+1
     end do
     do while (x < a(j))
        j=j-1
     end do
     if (i >= j) exit
     t = a(i);  a(i) = a(j);  a(j) = t
     i=i+1
     j=j-1
  end do
  if (first < i-1) call quicksort(a, first, i-1)
  if (j+1 < last)  call quicksort(a, j+1, last)
end subroutine quicksort


  END MODULE droplet_module
