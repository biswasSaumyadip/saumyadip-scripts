-- managed by setup.ps1
return {
  {
    "mfussenegger/nvim-jdtls",
    ft = "java",
    config = function()
      vim.api.nvim_create_autocmd("FileType", {
        pattern = "java",
        callback = function()
          local ok, jdtls = pcall(require, "jdtls")
          if not ok then
            return
          end

          local root_markers = { ".git", "mvnw", "gradlew", "pom.xml", "build.gradle", "build.gradle.kts" }
          local root = vim.fs.root(0, root_markers) or vim.fn.getcwd()
          local project = vim.fn.fnamemodify(root, ":p:h:t")
          local workspace = vim.fn.stdpath("data") .. "/jdtls-workspace/" .. project
          local mason = vim.fn.stdpath("data") .. "/mason/packages/jdtls"
          local launcher = vim.fn.glob(mason .. "/plugins/org.eclipse.equinox.launcher_*.jar")
          if launcher == "" then
            vim.notify("jdtls is not installed yet. Open :Mason and wait for install, then reopen the file.", vim.log.levels.WARN)
            return
          end

          local config_dir = mason .. "/config_win"
          if vim.fn.isdirectory(config_dir) == 0 then
            config_dir = mason .. "/config_linux"
          end

          local cmd = {
            "java",
            "-Declipse.application=org.eclipse.jdt.ls.core.id1",
            "-Dosgi.bundles.defaultStartLevel=4",
            "-Declipse.product=org.eclipse.jdt.ls.core.product",
            "-Dlog.protocol=true",
            "-Dlog.level=ALL",
            "-Xmx1G",
            "--add-modules=ALL-SYSTEM",
            "--add-opens",
            "java.base/java.util=ALL-UNNAMED",
            "--add-opens",
            "java.base/java.lang=ALL-UNNAMED",
            "-jar",
            launcher,
            "-configuration",
            config_dir,
            "-data",
            workspace,
          }

          local lombok = mason .. "/lombok.jar"
          if vim.fn.filereadable(lombok) == 1 then
            table.insert(cmd, 2, "-javaagent:" .. lombok)
          end

          jdtls.start_or_attach({
            cmd = cmd,
            root_dir = root,
            settings = {
              java = {
                format = { enabled = true },
                configuration = { updateBuildConfiguration = "interactive" },
              },
            },
          })
        end,
      })
    end,
  },
}
