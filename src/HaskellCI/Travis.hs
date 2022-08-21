-- | Take configuration, produce 'Travis'.
{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# OPTIONS_GHC -Wno-unused-matches #-}
module HaskellCI.Travis (
    makeTravis,
    travisHeader,
    ) where

import HaskellCI.Prelude

import qualified Data.Map.Strict                 as M
import qualified Data.Set                        as S
import qualified Distribution.Fields.Pretty      as C
import qualified Distribution.Package            as C
import qualified Distribution.Pretty             as C
import qualified Distribution.Types.VersionRange as C
import qualified Distribution.Version            as C

import Cabal.Project
import HaskellCI.Auxiliary
import HaskellCI.Compiler
import HaskellCI.Config
import HaskellCI.Config.ConstraintSet
import HaskellCI.Config.Doctest
import HaskellCI.Config.Folds
import HaskellCI.Config.HLint
import HaskellCI.Config.Installed
import HaskellCI.Config.Jobs
import HaskellCI.Config.PackageScope
import HaskellCI.Config.Validity
import HaskellCI.HeadHackage
import HaskellCI.Jobs
import HaskellCI.List
import HaskellCI.MonadErr
import HaskellCI.Package
import HaskellCI.Sh
import HaskellCI.ShVersionRange
import HaskellCI.Tools
import HaskellCI.Travis.Yaml
import HaskellCI.VersionInfo

-------------------------------------------------------------------------------
-- Travis header
-------------------------------------------------------------------------------

travisHeader :: Bool -> [String] -> [String]
travisHeader insertVersion argv =
    [ "This Travis job script has been generated by a script via"
    , ""
    , "  haskell-ci " ++ unwords [ "'" ++ a ++ "'" | a <- argv ]
    , ""
    , "To regenerate the script (for example after adjusting tested-with) run"
    , ""
    , "  haskell-ci regenerate"
    , ""
    , "For more information, see https://github.com/haskell-CI/haskell-ci"
    , ""
    ] ++
    if insertVersion then
    [ "version: " ++ haskellCIVerStr
    , ""
    ] else []

-------------------------------------------------------------------------------
-- Generate travis configuration
-------------------------------------------------------------------------------

{-
Travis CI–specific notes:

* We use -j2 for parallelism, as Travis' virtual environments use 2 cores, per
  https://docs.travis-ci.com/user/reference/overview/#virtualisation-environment-vs-operating-system.
-}

makeTravis
    :: [String]
    -> Config
    -> Project URI Void Package
    -> JobVersions
    -> Either HsCiError Travis -- TODO: writer
makeTravis argv config@Config {..} prj jobs@JobVersions {..} = do
    -- before caching: clear some redundant stuff
    beforeCache <- runSh $ when cfgCache $ do
        sh "rm -fv $CABALHOME/packages/hackage.haskell.org/build-reports.log"
        comment "remove files that are regenerated by 'cabal update'"
        sh "rm -fv $CABALHOME/packages/hackage.haskell.org/00-index.*" -- legacy
        sh "rm -fv $CABALHOME/packages/hackage.haskell.org/*.json" -- TUF meta-data
        sh "rm -fv $CABALHOME/packages/hackage.haskell.org/01-index.cache"
        sh "rm -fv $CABALHOME/packages/hackage.haskell.org/01-index.tar"
        sh "rm -fv $CABALHOME/packages/hackage.haskell.org/01-index.tar.idx"
        sh "rm -rfv $CABALHOME/packages/head.hackage" -- if we cache, it will break builds.

    -- before install: we set up the environment, install GHC/cabal on OSX
    beforeInstall <- runSh $ do
        -- Validity checks
        checkConfigValidity config jobs

        -- This have to be first
        when anyGHCJS $ sh $ unlines
            [ "if echo $CC | grep -q ghcjs; then"
            , "    GHCJS=true; GHCJSARITH=1;"
            , "else"
            , "    GHCJS=false; GHCJSARITH=0;"
            , "fi"
            ]

        -- Adjust $HC
        sh "HC=$(echo \"/opt/$CC/bin/ghc\" | sed 's/-/\\//')"
        sh "WITHCOMPILER=\"-w $HC\""
        shForJob RangeGHCJS "HC=${HC}js"
        shForJob RangeGHCJS "WITHCOMPILER=\"--ghcjs ${WITHCOMPILER}js\""

        -- Needed to work around haskell/cabal#6214
        sh "HADDOCK=$(echo \"/opt/$CC/bin/haddock\" | sed 's/-/\\//')"
        unless (null macosVersions) $ do
            sh $ "if [ \"$TRAVIS_OS_NAME\" = \"osx\" ]; then HADDOCK=$(echo $HADDOCK | sed \"s:^/opt:$HOME/.ghc-install:\"); fi"

        -- Hack: happy needs ghc. Let's install version matching GHCJS.
        -- At the moment, there is only GHCJS-8.4, so we install GHC-8.4.4
        when anyGHCJS $ do
            shForJob RangeGHCJS $ "PATH=\"/opt/ghc/8.4.4/bin:$PATH\""

        sh "HCPKG=\"$HC-pkg\""
        sh "unset CC"
        -- cabal
        sh "CABAL=/opt/ghc/bin/cabal"
        sh "CABALHOME=$HOME/.cabal"
        -- PATH
        sh "export PATH=\"$CABALHOME/bin:$PATH\""
        -- rootdir is useful for manual script additions
        sh "TOP=$(pwd)"
        -- macOS installing
        let haskellOnMacos = "https://haskell.futurice.com/haskell-on-macos.py"
        unless (null macosVersions) $ do
            sh $ "if [ \"$TRAVIS_OS_NAME\" = \"osx\" ]; then curl " ++ haskellOnMacos ++ " | python3 - --make-dirs --install-dir=$HOME/.ghc-install --cabal-alias=3.2.0.0 install cabal-install-3.2.0.0 ${TRAVIS_COMPILER}; fi"
            sh' [2034,2039] "if [ \"$TRAVIS_OS_NAME\" = \"osx\" ]; then HC=$HOME/.ghc-install/ghc/bin/$TRAVIS_COMPILER; WITHCOMPILER=\"-w $HC\"; HCPKG=$HOME/.ghc-install/ghc/bin/${TRAVIS_COMPILER}/ghc/ghc-pkg; CABAL=$HOME/.ghc-install/ghc/bin/cabal; fi"
        -- HCNUMVER, numeric HC version, e.g. ghc 7.8.4 is 70804 and 7.10.3 is 71003
        sh "HCNUMVER=$(${HC} --numeric-version|perl -ne '/^(\\d+)\\.(\\d+)\\.(\\d+)(\\.(\\d+))?$/; print(10000 * $1 + 100 * $2 + ($3 == 0 ? $5 != 1 : $3))')"
        sh "echo $HCNUMVER"
        -- verbose in .cabal/config is not respected
        -- https://github.com/haskell/cabal/issues/5956
        sh "CABAL=\"$CABAL -vnormal+nowrap\""

        -- SC2039: In POSIX sh, set option pipefail is undefined. Travis is bash, so it's fine :)
        sh' [2039, 3040] "set -o pipefail"

        sh "TEST=--enable-tests"
        shForJob (invertCompilerRange $ Range cfgTests) "TEST=--disable-tests"
        sh "BENCH=--enable-benchmarks"
        shForJob (invertCompilerRange $ Range cfgBenchmarks) "BENCH=--disable-benchmarks"
        sh "HEADHACKAGE=false"
        shForJob (Range cfgHeadHackage \/ RangePoints (S.singleton GHCHead)) "HEADHACKAGE=true"

        -- create ~/.cabal/config
        sh "rm -f $CABALHOME/config"
        cat "$CABALHOME/config"
            [ "verbose: normal +nowrap +markoutput" -- https://github.com/haskell/cabal/issues/5956
            , "remote-build-reporting: anonymous"
            , "write-ghc-environment-files: never"
            , "remote-repo-cache: $CABALHOME/packages"
            , "logs-dir:          $CABALHOME/logs"
            , "world-file:        $CABALHOME/world"
            , "extra-prog-path:   $CABALHOME/bin"
            , "symlink-bindir:    $CABALHOME/bin"
            , "installdir:        $CABALHOME/bin"
            , "build-summary:     $CABALHOME/logs/build.log"
            , "store-dir:         $CABALHOME/store"
            , "install-dirs user"
            , "  prefix: $CABALHOME"
            , "repository hackage.haskell.org"
            , "  url: http://hackage.haskell.org/"
            ]

        -- Add head.hackage repository to ~/.cabal/config
        -- (locally you want to add it to cabal.project)
        unless (S.null headGhcVers) $ sh $ unlines $
            [ "if $HEADHACKAGE; then"
            ] ++
            lines (catCmd Double "$CABALHOME/config" $ headHackageRepoStanza cfgHeadHackageOverride) ++
            [ "fi"
            ]

    -- in install step we install tools and dependencies
    install <- runSh $ do
        sh "${CABAL} --version"
        sh "echo \"$(${HC} --version) [$(${HC} --print-project-git-commit-id 2> /dev/null || echo '?')]\""
        when anyGHCJS $ do
            sh "node --version"
            sh "echo $GHCJS"

        -- Cabal jobs
        for_ (cfgJobs >>= cabalJobs) $ \n ->
            sh $ "echo 'jobs: " ++ show n ++ "' >> $CABALHOME/config"

        -- GHC jobs + ghc-options
        for_ (cfgJobs >>= ghcJobs) $ \m -> do
            shForJob (Range $ C.orLaterVersion (C.mkVersion [7,8])) $ "GHCJOBS=-j" ++ show m
        cat "$CABALHOME/config"
            [ "program-default-options"
            , "  ghc-options: $GHCJOBS +RTS -M6G -RTS"
            ]

        -- output config for debugging purposes
        sh "cat $CABALHOME/config"

        -- remove project own cabal.project files
        sh "rm -fv cabal.project cabal.project.local cabal.project.freeze"

        -- Update hackage index.
        sh "travis_retry ${CABAL} v2-update -v"

        -- Install doctest
        let doctestVersionConstraint
                | C.isAnyVersion (cfgDoctestVersion cfgDoctest) = ""
                | otherwise = " --constraint='doctest " ++ C.prettyShow (cfgDoctestVersion cfgDoctest) ++ "'"
        when doctestEnabled $
            shForJob (Range (cfgDoctestEnabled cfgDoctest) /\ doctestJobVersionRange) $
                cabal $ "v2-install $WITHCOMPILER --ignore-project -j2 doctest" ++ doctestVersionConstraint

        -- Install hlint
        let hlintVersionConstraint
                | C.isAnyVersion (cfgHLintVersion cfgHLint) = ""
                | otherwise = " --constraint='hlint " ++ C.prettyShow (cfgHLintVersion cfgHLint) ++ "'"
        when (cfgHLintEnabled cfgHLint) $ do
            let forHLint = shForJob (hlintJobVersionRange allVersions  cfgHeadHackage (cfgHLintJob cfgHLint))
            if cfgHLintDownload cfgHLint
            then do
                -- install --dry-run and use perl regex magic to find a hlint version
                -- -v is important
                forHLint $ "HLINTVER=$(cd /tmp && (${CABAL} v2-install -v $WITHCOMPILER --dry-run hlint " ++ hlintVersionConstraint ++ " |  perl -ne 'if (/\\bhlint-(\\d+(\\.\\d+)*)\\b/) { print \"$1\"; last; }')); echo \"HLint version $HLINTVER\""
                forHLint $ "if [ ! -e $HOME/.hlint/hlint-$HLINTVER/hlint ]; then " ++ unwords
                    [ "echo \"Downloading HLint version $HLINTVER\";"
                    , "mkdir -p $HOME/.hlint;"
                    , "curl --write-out 'Status Code: %{http_code} Redirects: %{num_redirects} Total time: %{time_total} Total Dsize: %{size_download}\\n' --silent --location --output $HOME/.hlint/hlint-$HLINTVER.tar.gz \"https://github.com/ndmitchell/hlint/releases/download/v$HLINTVER/hlint-$HLINTVER-x86_64-linux.tar.gz\";"
                    , "tar -xzv -f $HOME/.hlint/hlint-$HLINTVER.tar.gz -C $HOME/.hlint;"
                    , "fi"
                    ]
                forHLint "mkdir -p $CABALHOME/bin && ln -sf \"$HOME/.hlint/hlint-$HLINTVER/hlint\" $CABALHOME/bin/hlint"
                forHLint "hlint --version"

            else forHLint $ cabal $ "v2-install $WITHCOMPILER --ignore-project -j2 hlint" ++ hlintVersionConstraint

        -- Install cabal-plan (for ghcjs tests)
        when (anyGHCJS && cfgGhcjsTests) $ do
            shForJob RangeGHCJS $ cabal "v2-install -w ghc-8.4.4 --ignore-project -j2 cabal-plan --constraint='cabal-plan ^>=0.6.0.0' --constraint='cabal-plan +exe'"

        -- Install happy
        when anyGHCJS $ for_ cfgGhcjsTools $ \t ->
            shForJob RangeGHCJS $ cabal $ "v2-install -w ghc-8.4.4 --ignore-project -j2" ++ C.prettyShow t

        -- create cabal.project file
        generateCabalProject False

        -- autoreconf
        for_ pkgs $ \Pkg{pkgDir} ->
            sh $ "if [ -f \"" ++ pkgDir ++ "/configure.ac\" ]; then (cd \"" ++ pkgDir ++ "\" && autoreconf -i); fi"

        -- dump install plan
        sh $ cabal "v2-freeze $WITHCOMPILER ${TEST} ${BENCH}"
        sh "cat cabal.project.freeze | sed -E 's/^(constraints: *| *)//' | sed 's/any.//'"
        sh "rm  cabal.project.freeze"

        -- Install dependencies
        when cfgInstallDeps $ do
            -- install dependencies
            sh $ cabalTW "v2-build $WITHCOMPILER ${TEST} ${BENCH} --dep -j2 all"

            -- install dependencies for no-test-no-bench
            shForJob (Range cfgNoTestsNoBench) $ cabalTW "v2-build $WITHCOMPILER --disable-tests --disable-benchmarks --dep -j2 all"

    -- Here starts the actual work to be performed for the package under test;
    -- any command which exits with a non-zero exit code causes the build to fail.
    script <- runSh $ do
        sh "DISTDIR=$(mktemp -d /tmp/dist-test.XXXX)"

        -- sdist
        foldedSh FoldSDist "Packaging..." cfgFolds $ do
            sh $ cabal "v2-sdist all"

        -- unpack
        foldedSh FoldUnpack "Unpacking..." cfgFolds $ do
            sh "mv dist-newstyle/sdist/*.tar.gz ${DISTDIR}/"
            sh "cd ${DISTDIR} || false" -- fail explicitly, makes SC happier
            sh "find . -maxdepth 1 -type f -name '*.tar.gz' -exec tar -xvf '{}' \\;"
            sh "find . -maxdepth 1 -type f -name '*.tar.gz' -exec rm       '{}' \\;"

            for_ pkgs $ \Pkg{pkgName} -> do
                sh $ pkgNameDirVariable' pkgName ++ "=\"$(find . -maxdepth 1 -type d -regex '.*/" ++ pkgName ++ "-[0-9.]*')\""

            generateCabalProject True

            when (anyGHCJS && cfgGhcjsTests) $ sh $ unlines $
                [ "pkgdir() {"
                , "  case $1 in"
                ] ++
                [ "    " ++ pkgName ++ ") echo " ++ pkgNameDirVariable pkgName ++ " ;;"
                | Pkg{pkgName} <- pkgs
                ] ++
                [ "  esac"
                , "}"
                ]

        -- build no-tests no-benchmarks
        unless (equivVersionRanges C.noVersion cfgNoTestsNoBench) $ foldedSh FoldBuild "Building..." cfgFolds $ do
            comment "this builds all libraries and executables (without tests/benchmarks)"
            shForJob (Range cfgNoTestsNoBench) $ cabal "v2-build $WITHCOMPILER --disable-tests --disable-benchmarks all"

        -- build everything
        foldedSh FoldBuildEverything "Building with tests and benchmarks..." cfgFolds $ do
            comment "build & run tests, build benchmarks"
            sh $ cabal "v2-build $WITHCOMPILER ${TEST} ${BENCH} all --write-ghc-environment-files=always"

        -- cabal v2-test fails if there are no test-suites.
        foldedSh FoldTest "Testing..." cfgFolds $ do
            shForJob (RangeGHC /\ Range (cfgTests /\ cfgRunTests) /\ hasTests) $
                cabal $ "v2-test $WITHCOMPILER ${TEST} ${BENCH} all" ++ testShowDetails

            when cfgGhcjsTests $ shForJob (RangeGHCJS /\ hasTests) $ unwords
                [ "cabal-plan list-bins '*:test:*' | while read -r line; do"
                , "testpkg=$(echo \"$line\" | perl -pe 's/:.*//');"
                , "testexe=$(echo \"$line\" | awk '{ print $2 }');"
                , "echo \"testing $textexe in package $textpkg\";"
                , "(cd \"$(pkgdir $testpkg)\" && nodejs \"$testexe\".jsexe/all.js);"
                , "done"
                ]

        -- doctest
        when doctestEnabled $ foldedSh FoldDoctest "Doctest..." cfgFolds $ do
            let doctestOptions = unwords $ cfgDoctestOptions cfgDoctest
            sh $ "$CABAL v2-build $WITHCOMPILER ${TEST} ${BENCH} all --dry-run"
            unless (null $ cfgDoctestFilterEnvPkgs cfgDoctest) $ do
                -- cabal-install mangles unit ids on the OSX,
                -- removing the vowels to make filepaths shorter
                let manglePkgNames :: String -> [String]
                    manglePkgNames n
                        | null macosVersions = [n]
                        | otherwise          = [n, filter notVowel n]
                      where
                        notVowel c = notElem c ("aeiou" :: String)
                let filterPkgs = intercalate "|" $ concatMap (manglePkgNames . C.unPackageName) $ cfgDoctestFilterEnvPkgs cfgDoctest
                sh $ "perl -i -e 'while (<ARGV>) { print unless /package-id\\s+(" ++ filterPkgs ++ ")-\\d+(\\.\\d+)*/; }' .ghc.environment.*"
            for_ pkgs $ \Pkg{pkgName,pkgGpd,pkgJobs} ->
                when (C.mkPackageName pkgName `notElem` cfgDoctestFilterSrcPkgs cfgDoctest) $ do
                    for_ (doctestArgs pkgGpd) $ \args -> do
                        let args' = unwords args
                        let vr = Range (cfgDoctestEnabled cfgDoctest)
                              /\ doctestJobVersionRange
                              /\ RangePoints pkgJobs
                        unless (null args) $ shForJob  vr $
                            "(cd " ++ pkgNameDirVariable pkgName ++ " && doctest " ++ doctestOptions ++ " " ++ args' ++ ")"

        -- hlint
        when (cfgHLintEnabled cfgHLint) $ foldedSh FoldHLint "HLint.." cfgFolds $ do
            let "" <+> ys = ys
                xs <+> "" = xs
                xs <+> ys = xs ++ " " ++ ys

                prependSpace "" = ""
                prependSpace xs = " " ++ xs

            let hlintOptions = prependSpace $ maybe "" ("-h ${TOP}/" ++) (cfgHLintYaml cfgHLint) <+> unwords (cfgHLintOptions cfgHLint)

            for_ pkgs $ \Pkg{pkgName,pkgGpd,pkgJobs} -> do
                for_ (hlintArgs pkgGpd) $ \args -> do
                    let args' = unwords args
                    unless (null args) $
                        shForJob (hlintJobVersionRange allVersions cfgHeadHackage (cfgHLintJob cfgHLint) /\ RangePoints pkgJobs) $
                        "(cd " ++ pkgNameDirVariable pkgName ++ " && hlint" ++ hlintOptions ++ " " ++ args' ++ ")"

        -- cabal check
        when cfgCheck $ foldedSh FoldCheck "cabal check..." cfgFolds $ do
            for_ pkgs $ \Pkg{pkgName,pkgJobs} -> shForJob (RangePoints pkgJobs) $
                "(cd " ++ pkgNameDirVariable pkgName ++ " && ${CABAL} -vnormal check)"

        -- haddock
        when (not (equivVersionRanges C.noVersion cfgHaddock)) $
            foldedSh FoldHaddock "haddock..." cfgFolds $
                shForJob (RangeGHC /\ Range cfgHaddock) $ cabal $ "v2-haddock --haddock-all $WITHCOMPILER " ++ withHaddock ++ " ${TEST} ${BENCH} all"

        -- unconstained build
        -- Have to build last, as we remove cabal.project.local
        unless (equivVersionRanges C.noVersion cfgUnconstrainted) $
            foldedSh FoldBuildInstalled "Building without installed constraints for packages in global-db..." cfgFolds $ do
                shForJob (Range cfgUnconstrainted) "rm -f cabal.project.local"
                shForJob (Range cfgUnconstrainted) $ cabal "v2-build $WITHCOMPILER --disable-tests --disable-benchmarks all"

        -- and now, as we don't have cabal.project.local;
        -- we can test with other constraint sets
        unless (null cfgConstraintSets) $ do
            comment "Constraint sets"
            sh "rm -f cabal.project.local"

            for_ cfgConstraintSets $ \cs -> do
                let name            = csName cs
                let shForCs         = shForJob (Range (csGhcVersions cs))
                let shForCs' r      = shForJob (Range (csGhcVersions cs) /\ r)
                let testFlag        = if csTests cs then "--enable-tests" else "--disable-tests"
                let benchFlag       = if csBenchmarks cs then "--enable-benchmarks" else "--disable-benchmarks"
                let constraintFlags = map (\x ->  "--constraint='" ++ x ++ "'") (csConstraints cs)
                let allFlags        = unwords (testFlag : benchFlag : constraintFlags)

                foldedSh' FoldConstraintSets name ("Constraint set " ++ name) cfgFolds $ do
                    shForCs $ cabal $ "v2-build $WITHCOMPILER " ++ allFlags ++ " --dependencies-only -j2 all"
                    shForCs $ cabal $ "v2-build $WITHCOMPILER " ++ allFlags ++ " all"
                    when (csRunTests cs) $
                        shForCs' hasTests $ cabal $ "v2-test $WITHCOMPILER " ++ allFlags ++ " all --test-show-details=direct"
                    when (csHaddock cs) $
                        shForCs $ cabal $ "v2-haddock --haddock-all $WITHCOMPILER " ++ withHaddock ++ " " ++ allFlags ++ " all"

        -- At the end, we allow some raw travis scripts
        unless (null cfgRawTravis) $ do
            comment "Raw travis commands"
            traverse_ sh
                [ l
                | l <- lines cfgRawTravis
                , not (null l)
                ]

    -- assemble travis configuration
    return Travis
        { travisLanguage      = "c"
        , travisUbuntu        = cfgUbuntu
        , travisGit           = TravisGit
            { tgSubmodules = cfgSubmodules
            }
        , travisCache         = TravisCache
            { tcDirectories = buildList $ when cfgCache $ do
                item "$HOME/.cabal/packages"
                item "$HOME/.cabal/store"
                item "$HOME/.hlint"
                -- on OSX ghc is installed in $HOME so we can cache it
                -- independently of linux
                when (cfgCache && not (null macosVersions)) $ do
                    item "$HOME/.ghc-install"
            }
        , travisBranches      = TravisBranches
            { tbOnly = cfgOnlyBranches
            }
        , travisNotifications = TravisNotifications
            { tnIRC = justIf (not $ null cfgIrcChannels) $ TravisIRC
                { tiChannels = cfgIrcChannels
                , tiSkipJoin = True
                , tiTemplate =
                    [ "\x0313" ++ projectName ++ "\x03/\x0306%{branch}\x03 \x0314%{commit}\x03 %{build_url} %{message}"
                    ]
                , tiNick     = cfgIrcNickname
                , tiPassword = cfgIrcPassword
                }
            , tnEmail = cfgEmailNotifications
            }
        , travisServices      = buildList $ do
            when cfgPostgres $ item "postgresql"
        , travisAddons        = TravisAddons
            { taApt          = TravisApt [] []
            , taPostgres     = if cfgPostgres then Just "10" else Nothing
            , taGoogleChrome = cfgGoogleChrome
            }
        , travisMatrix        = TravisMatrix
            { tmInclude = buildList $ do
                let tellJob :: Bool -> CompilerVersion -> ListBuilder TravisJob ()
                    tellJob osx gv = do
                        let cvs = dispCabalVersion $ correspondingCabalVersion cfgCabalInstallVersion gv
                        let gvs = dispGhcVersion gv

                        -- https://docs.travis-ci.com/user/installing-dependencies/#adding-apt-sources
                        let hvrppa :: TravisAptSource
                            hvrppa = TravisAptSourceLine ("deb http://ppa.launchpad.net/hvr/ghc/ubuntu " ++ C.prettyShow cfgUbuntu ++ " main") (Just "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x063dab2bdc0b3f9fcebc378bff3aeacef6f88286")

                        let ghcjsAptSources :: [TravisAptSource]
                            ghcjsAptSources | not (isGHCJS gv) = []
                                            | otherwise =
                                [ TravisAptSourceLine ("deb http://ppa.launchpad.net/hvr/ghcjs/ubuntu " ++ C.prettyShow cfgUbuntu ++ " main") Nothing
                                , TravisAptSourceLine ("deb https://deb.nodesource.com/node_10.x " ++ C.prettyShow cfgUbuntu ++ " main") (Just "https://deb.nodesource.com/gpgkey/nodesource.gpg.key")
                                ]

                        let ghcjsPackages :: [String]
                            ghcjsPackages = case maybeGHCJS gv of
                                Just v -> [ "ghc-" ++ C.prettyShow v', "nodejs" ] where
                                    -- TODO: partial maximum
                                    v' = maximum $ filter (`C.withinRange` C.withinVersion v) $ knownGhcVersions
                                Nothing -> []

                        item TravisJob
                            { tjCompiler = gvs
                            , tjOS       = if osx then "osx" else "linux"
                            , tjEnv      = case gv of
                                GHC v -> M.lookup v cfgEnv
                                _     -> Nothing
                            , tjAddons   = TravisAddons
                                { taApt = TravisApt
                                    { taPackages = gvs : ("cabal-install-" ++ cvs) : ghcjsPackages ++ S.toList cfgApt
                                    , taSources  = hvrppa : ghcjsAptSources
                                    }

                                , taPostgres     = Nothing
                                , taGoogleChrome = False
                                }
                            }

                for_ (reverse $ S.toList linuxVersions) $ tellJob False
                for_ (reverse $ S.toList macosVersions) $ tellJob True

            , tmAllowFailures =
                [ TravisAllowFailure $ dispGhcVersion compiler
                | compiler <- toList allVersions
                , previewGHC cfgHeadHackage compiler || maybeGHC False (`C.withinRange` cfgAllowFailures) compiler
                ]
            }
        , travisBeforeCache   = beforeCache
        , travisBeforeInstall = beforeInstall
        , travisInstall       = install
        , travisScript        = script
        }
  where
    Auxiliary {..} = auxiliary config prj jobs

    justIf True x  = Just x
    justIf False _ = Nothing

    -- TODO: should this be part of MonadSh ?
    foldedSh label = foldedSh' label ""

    anyGHCJS = any isGHCJS allVersions

    -- https://github.com/travis-ci/docs-travis-ci-com/issues/949#issuecomment-276755003
    -- https://github.com/travis-ci/travis-rubies/blob/9f7962a881c55d32da7c76baefc58b89e3941d91/build.sh#L38-L44
    -- https://github.com/travis-ci/travis-build/blob/91bf066/lib/travis/build/shell/dsl.rb#L58-L63
    foldedSh' :: Fold -> String -> String -> Set Fold -> ShM () -> ShM ()
    foldedSh' label sfx plabel labels block
        | label `S.notMember` labels = commentedBlock plabel block
        | otherwise = case runSh block of
            Left err  -> throwErr err
            Right shs
                | all isComment shs -> pure ()
                | otherwise         -> ShM $ \shs1 -> Right $
                    ( shs1
                    . (Comment plabel :)
                    . (Sh ("echo '" ++ plabel ++ "' && echo -en 'travis_fold:start:" ++ label' ++ "\\\\r'") :)
                    . (shs ++)
                    . (Sh ("echo -en 'travis_fold:end:" ++ label' ++ "\\\\r'") :)
                    -- return ()
                    , ()
                    )
      where
        label' | null sfx  = showFold label
               | otherwise = showFold label ++ "-" ++ sfx


    -- GHC versions which need head.hackage
    headGhcVers :: Set CompilerVersion
    headGhcVers = S.filter (previewGHC cfgHeadHackage) allVersions

    cabal :: String -> String
    cabal cmd = "${CABAL} " ++ cmd

    cabalTW :: String -> String
    cabalTW cmd = "travis_wait 40 ${CABAL} " ++ cmd

    forJob :: CompilerRange -> String -> Maybe String
    forJob vr cmd
        | all (`compilerWithinRange` vr) allVersions       = Just cmd
        | not $ any (`compilerWithinRange` vr) allVersions = Nothing
        | otherwise                                        = Just $ unwords
            [ "if"
            , compilerVersionPredicate allVersions vr
            , "; then"
            , cmd
            , "; fi"
            ]

    shForJob :: CompilerRange -> String -> ShM ()
    shForJob vr cmd = maybe (pure ()) sh (forJob vr cmd)

    -- catForJob vr fp contents = shForJob vr (catCmd Double fp contents)

    generateCabalProject :: Bool -> ShM ()
    generateCabalProject dist = do
        comment "Generate cabal.project"
        sh "rm -rf cabal.project cabal.project.local cabal.project.freeze"
        sh "touch cabal.project"

        sh $ unlines
            [ cmd
            | pkg <- pkgs
            , let p | dist      = pkgNameDirVariable (pkgName pkg)
                    | otherwise = pkgDir pkg
            , cmd <- toList $ forJob (RangePoints $ pkgJobs pkg) $
                "echo \"packages: " ++ p ++ "\" >> cabal.project"
            ]

        case cfgErrorMissingMethods of
            PackageScopeNone  -> pure ()
            PackageScopeLocal -> for_ pkgs $ \Pkg{pkgName,pkgJobs} -> do
                shForJob (Range (C.orLaterVersion (C.mkVersion [8,2])) /\ RangePoints pkgJobs) $
                    "echo 'package " ++ pkgName ++ "' >> cabal.project"
                shForJob (Range (C.orLaterVersion (C.mkVersion [8,2])) /\ RangePoints pkgJobs) $
                    "echo '  ghc-options: -Werror=missing-methods' >> cabal.project"
            PackageScopeAll   -> do
                sh "echo 'package *' >> cabal.project"
                sh "echo '  ghc-options: -Werror=missing-methods' >> cabal.project"

        cat "cabal.project" $ lines $ C.showFields' (const C.NoComment) (const id) 2 $ extraCabalProjectFields ""

        -- If using head.hackage, allow building with newer versions of GHC boot libraries.
        -- Note that we put this in a cabal.project file, not ~/.cabal/config, in order to avoid
        -- https://github.com/haskell/cabal/issues/7291.
        unless (S.null headGhcVers) $ sh $ unlines $
            [ "if $HEADHACKAGE; then"
            , "echo \"allow-newer: $($HCPKG list --simple-output | sed -E 's/([a-zA-Z-]+)-[0-9.]+/*:\\1,/g')\" >> $CABALHOME/config"
            , "fi"
            ]

        -- also write cabal.project.local file with
        -- @
        -- constraints: base installed
        -- constraints: array installed
        -- ...
        --
        -- omitting any local package names
        case normaliseInstalled cfgInstalled of
            InstalledDiff pns -> sh $ unwords
                [ "for pkg in $($HCPKG list --simple-output); do"
                , "echo $pkg"
                , "| sed 's/-[^-]*$//'"
                , "| (grep -vE -- " ++ re ++ " || true)"
                , "| sed 's/^/constraints: /'"
                , "| sed 's/$/ installed/'"
                , ">> cabal.project.local; done"
                ]
              where
                pns' = S.map C.unPackageName pns `S.union` foldMap (S.singleton . pkgName) pkgs
                re = "'^(" ++ intercalate "|" (S.toList pns') ++ ")$'"

            InstalledOnly pns | not (null pns') -> sh' [2043] $ unwords
                [ "for pkg in " ++ unwords (S.toList pns') ++ "; do"
                , "echo \"constraints: $pkg installed\""
                , ">> cabal.project.local; done"
                ]
              where
                pns' = S.map C.unPackageName pns `S.difference` foldMap (S.singleton . pkgName) pkgs

            -- otherwise: nothing
            _ -> pure ()

        sh "cat cabal.project || true"
        sh "cat cabal.project.local || true"

    -- Needed to work around haskell/cabal#6214
    withHaddock :: String
    withHaddock = "--with-haddock $HADDOCK"



data Quotes = Single | Double

escape :: Quotes -> String -> String
escape Single xs = "'" ++ concatMap f xs ++ "'" where
    f '\0' = ""
    f '\'' = "'\"'\"'"
    f x    = [x]
escape Double xs = show xs

catCmd :: Quotes -> FilePath -> [String] -> String
catCmd q fp contents = unlines
    [ "echo " ++ escape q l ++ replicate (maxLength - length l) ' ' ++ " >> " ++ fp
    | l <- contents
    ]
  where
    maxLength = foldl' (\a l -> max a (length l)) 0 contents
{-
-- https://travis-ci.community/t/multiline-commands-have-two-spaces-in-front-breaks-heredocs/2756
catCmd fp contents = unlines $
    [ "cat >> " ++ fp ++ " << HEREDOC" ] ++
    contents ++
    [ "HEREDOC" ]
-}

cat :: FilePath -> [String] -> ShM ()
cat fp contents = sh $ catCmd Double fp contents
