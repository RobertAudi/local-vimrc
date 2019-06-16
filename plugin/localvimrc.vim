let s:last_cwd = ''

fun! s:init()
  if get(s:, 'local_vimrc_did_init', 0)
    return
  endif

  if !exists('g:local_vimrc') | let g:local_vimrc = {} | endif

  " using .vimrc because most systems support local and user global
  " configuration files. They rarely differ in name.
  " Users will instantly understand what it does.
  let g:local_vimrc.names = get(g:local_vimrc, 'names', ['.vimrc'])
  let g:local_vimrc.overwriter_names = get(g:local_vimrc, 'overwriter_names', ['.overwrite.vimrc'])

  let g:local_vimrc.hash_fun = get(g:local_vimrc,'hash_fun','LVRHashOfFile')
  let g:local_vimrc.cache_file = get(g:local_vimrc,'cache_file', $HOME.'/.vim_local_rc_cache')
  let g:local_vimrc.resource_on_cwd_change = get(g:local_vimrc, 'resource_on_cwd_change', 1)
  let g:local_vimrc.implementations = get(g:local_vimrc, 'implementations', ['sha512sum', 'sha256sum', 'sha1sum', 'md5sum', 'viml'])
  let g:local_vimrc.ignore = get(g:local_vimrc, 'ignore', [])

  let s:local_vimrc_did_init = 1
endfun

" very simple hash function using md5 falling back to VimL implementation
fun! LVRHashOfFile(file, seed)

  for i in g:local_vimrc.implementations
    if i == 'viml'
      let s = join(readfile(a:file,"\n"))
      " poor mans hash function. I don't expect it to be very secure.
      let sum = a:seed
      for i in range(0,len(s)-1)
        let sum = ((sum + char2nr(s[i]) * i) - i) / 2
      endfor
      return sum.''
    elseif executable(i)
      return system(i.' '.shellescape(a:file))
    endif
  endfor
  throw "no LVRHashOfFile implementation suceeded"
endfun

" source local vimrc, ask user for confirmation if file contents change
fun! LVRSource(file, cache)
  let p = expand(a:file)

  " always ignore user global .vimrc which Vim sources on startup:
  if p == expand("~/.vimrc") | return | endif

  if !empty(g:local_vimrc.ignore)
    for i in g:local_vimrc.ignore
      if p =~ expand(i) | return | endif
    endfor
  endif

  let h = call(function(g:local_vimrc.hash_fun), [a:file, a:cache.seed])
  " if hash doesn't match or no hash exists ask user to confirm sourcing this file
  if get(a:cache, p, 'no-hash') == h
    let a:cache[p] = h
    exec 'source '.fnameescape(p)
  else
    let choice = confirm('source '.p,"&Yes\nNo\n&View",2)
    if choice == 1
      let a:cache[p] = h
      exec 'source '.fnameescape(p)
    elseif choice == 3
      exec 'e '.fnameescape(p)
      echo "Execute :SourceLocalVimrc after confirming the vimrc file is safe."
    endif
  endif
endf

fun! LVRWithCache(F, args)
  " for each computer use different unique seed based on time so that its
  " harder to find collisions
  let cache = filereadable(g:local_vimrc.cache_file)
        \ ? eval(readfile(g:local_vimrc.cache_file)[0])
        \ : {'seed':localtime()}
  let c = copy(cache)
  let r = call(a:F, [cache]+a:args)
  if c != cache | call writefile([string(cache)], g:local_vimrc.cache_file) | endif
  return r
endf

" find all local .vimrc in parent directories
fun! LVRRecurseUp(cache, dir, names)
  let s:last_cwd = a:dir
  let files = []
  for n in a:names
    let nr = 1
    while 1
      " ".;" does not work in the "vim ." case - why?
      " Thanks to github.com/jdonaldson (Justin Donaldso) for finding this issue
      " The alternative fix would be calling SourceLocalVimrcOnce
      " at VimEnter, however I feel that you cannot setup additional VimEnter
      " commands then - thus preferring getcwd()
      let f = findfile(n, escape(getcwd(), "\ ").";", nr)
      if f == '' | break | endif
      call add(files, fnamemodify(f,':p'))
      let nr += 1
    endwhile
  endfor
  call map(reverse(files), 'LVRSource(v:val, a:cache)')
endf

" find and source files on vim startup:
command! SourceLocalVimrc call LVRWithCache('LVRRecurseUp', [getcwd(), g:local_vimrc.names] )
command! SourceLocalVimrcOnce
    \ if g:local_vimrc.resource_on_cwd_change && s:last_cwd != getcwd()
    \ | call LVRWithCache('LVRRecurseUp', [getcwd(), g:local_vimrc.names] )
    \ | endif

" if its you writing a file update hash automatically
fun! LVRUpdateCache(cache)
  let f = expand('%:p')
  let a:cache[f] = call(function(g:local_vimrc.hash_fun), [f, a:cache.seed])
endf

augroup LOCAL_VIMRC
  autocmd!

  " If the current file is a local .vimrc file and you're writing it
  " automatically update the cache
  autocmd BufWritePost * call s:init() | if index(g:local_vimrc.names, expand('%:t')) >= 0 | call LVRWithCache('LVRUpdateCache', [] ) | endif

  " If autochdir is not set, then resource local vimrc files if current
  " directory has changed. There is no event for signaling change of current
  " directory - so this is only an approximation to what people might expect.
  " Idle events and the like would be an alternative
  if ! &autochdir
    autocmd BufNewFile,BufRead * call s:init() | SourceLocalVimrcOnce
  endif

  autocmd VimEnter * call s:init() | SourceLocalVimrcOnce
  autocmd VimEnter,BufNewFile,BufRead * call s:init() | call LVRWithCache('LVRRecurseUp', [getcwd(), g:local_vimrc.overwriter_names] )
augroup end
