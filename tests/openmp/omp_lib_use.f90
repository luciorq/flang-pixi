program omp_lib_use
  use omp_lib
  implicit none
  integer :: nt
  nt = -1
  !$omp parallel
  !$omp master
  nt = omp_get_num_threads()
  !$omp end master
  !$omp end parallel
  print '(a,i0,a,i0)', 'threads=', nt, ' max=', omp_get_max_threads()
  if (nt < 1) stop 1
end program
