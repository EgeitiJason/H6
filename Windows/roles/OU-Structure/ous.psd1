# OU hierarchy under the domain root - modify this structure to change OUs.
# Leaf OUs under Users are departments: each gets an SG- group (Users role) and
# a folder in Afdelinger (FileServer role), unless marked Department = $false.
@{
    OUs = @(
        @{
            Name = "Middelfart Racing"
            Children = @(
                @{
                    Name = "Computers"
                    Children = @()
                },
                @{
                    Name = "Groups"
                    Children = @(
                        @{ Name = "Apps" },
                        @{ Name = "Fileshares" },
                        @{ Name = "Wifi" }
                    )
                },
                @{
                    Name = "Servers"
                    Children = @()
                },
                @{
                    Name = "Users"
                    Children = @(
                        @{ Name = "Admin"; Department = $false },
                        @{
                            Name = "Administration"
                            Children = @(
                                @{ Name = "IT" },
                                @{ Name = "HR" },
                                @{ Name = "Finans" }
                            )
                        },
                        @{ Name = "Lager" },
                        @{ Name = "Service Accounts"; Department = $false }
                    )
                }
            )
        }
    )
}
